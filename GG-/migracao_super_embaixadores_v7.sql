-- ==============================================================================
-- GEF | MIGRAÇÃO v7: GESTÃO DE EMBAIXADORES E SUPER EMBAIXADORES (idempotente)
-- Só ADICIONA / substitui funções (CREATE OR REPLACE, sem DROP ... CASCADE).
-- Pré-requisito: v2, v4 e v6 já executadas (ordem: v2 -> v3 -> v4 -> v5 -> v6 -> v7).
--
-- Modelo (reutiliza a v6): perfil de login continua 'EMBAIXADOR' em public.profiles.role;
-- o Super Embaixador é ambassadors.is_super = TRUE (fonte única de verdade, no servidor).
--
--  1. Colunas novas em ambassadors (contactos, idioma, moeda, área geográfica, eliminação lógica, motivo de bloqueio)
--  2. Auditoria (ambassador_audit_log) e registo de transferências (ambassador_transfers)
--  3. Pacotes de mensalidade editáveis (ambassador_fee_packages, semeados com os 4 planos que já existiam no ecrã)
--  4. Vigência de comissões (ambassador_rate_schedule) — reutiliza fn_admin_set_ambassador_rates da v6
--  5. Bloqueio: fn_ambassador_resolve passa a bloquear SEMPRE (inclui leitura por RPC) + portal + RLS
--  6. SUPERADMIN: criar perfis, promover/despromover, transferir, editar área/idioma/moeda, eliminar logicamente
--  7. SUPER EMBAIXADOR: rede própria (leitura) e cadastro de Embaixadores normais
--  8. Contexto do utilizador (idioma/moeda/bloqueio/contacto do Super Embaixador)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. COLUNAS
-- ------------------------------------------------------------------------------
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS email TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS whatsapp TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS language TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS currency TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS geo_country TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS geo_province TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS geo_district TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS geo_city TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS geo_neighborhood TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS geo_description TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS effective_from DATE;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS block_reason TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS blocked_by_role TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS deleted_by UUID;

CREATE INDEX IF NOT EXISTS idx_ambassadors_geo ON public.ambassadors(geo_country, geo_province, geo_city);

-- Listas válidas = as que já existem no sistema (js/core/i18n.js: SUPPORTED_LANGUAGES / SUPPORTED_CURRENCIES).
CREATE OR REPLACE FUNCTION public.fn_valid_language(p TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$ SELECT p IN ('pt', 'en'); $$;
CREATE OR REPLACE FUNCTION public.fn_valid_currency(p TEXT) RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE AS $$ SELECT p IN ('MT', 'Kz', 'R$', 'R', '$'); $$;

-- Registos antigos têm NULL (continuam válidos); valores gravados têm de pertencer às listas.
DO $$ BEGIN
    ALTER TABLE public.ambassadors ADD CONSTRAINT chk_amb_language CHECK (language IS NULL OR public.fn_valid_language(language));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TABLE public.ambassadors ADD CONSTRAINT chk_amb_currency CHECK (currency IS NULL OR public.fn_valid_currency(currency));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ------------------------------------------------------------------------------
-- 2. AUDITORIA + TRANSFERÊNCIAS (sem política de escrita: só funções SECURITY DEFINER gravam)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ambassador_audit_log (
    id BIGSERIAL PRIMARY KEY,
    action TEXT NOT NULL,
    ambassador_id TEXT,
    store_ref_id TEXT,
    actor_id UUID DEFAULT auth.uid(),
    actor_role TEXT,
    reason TEXT,
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_amb_audit_amb ON public.ambassador_audit_log(ambassador_id, created_at DESC);
ALTER TABLE public.ambassador_audit_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "amb_audit_superadmin_select" ON public.ambassador_audit_log;
CREATE POLICY "amb_audit_superadmin_select" ON public.ambassador_audit_log FOR SELECT TO authenticated
USING (public.fn_is_superadmin());

CREATE TABLE IF NOT EXISTS public.ambassador_transfers (
    id BIGSERIAL PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('AMBASSADOR', 'STORE')),
    subject_id TEXT NOT NULL,          -- embaixador transferido, ou loja indicada (ambassador_referred_stores.id)
    from_id TEXT,
    to_id TEXT,
    reason TEXT NOT NULL,
    effective_date DATE NOT NULL DEFAULT CURRENT_DATE,
    performed_by UUID DEFAULT auth.uid(),
    performed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    details JSONB
);
ALTER TABLE public.ambassador_transfers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "amb_transfers_superadmin_select" ON public.ambassador_transfers;
CREATE POLICY "amb_transfers_superadmin_select" ON public.ambassador_transfers FOR SELECT TO authenticated
USING (public.fn_is_superadmin());

CREATE OR REPLACE FUNCTION public.fn_amb_audit(p_action TEXT, p_amb TEXT, p_store TEXT, p_reason TEXT, p_details JSONB)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
    INSERT INTO public.ambassador_audit_log(action, ambassador_id, store_ref_id, actor_id, actor_role, reason, details)
    VALUES (p_action, p_amb, p_store, auth.uid(), public.get_auth_user_role(), p_reason, p_details);
$$;
REVOKE ALL ON FUNCTION public.fn_amb_audit(TEXT, TEXT, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 3. PACOTES DE MENSALIDADE (os 4 planos que estavam fixos no ecrã passam a ser dados editáveis)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ambassador_fee_packages (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    monthly_fee NUMERIC(12, 2) NOT NULL CHECK (monthly_fee >= 0),
    sort_order INT NOT NULL DEFAULT 0,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
ALTER TABLE public.ambassador_fee_packages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "amb_fee_packages_read" ON public.ambassador_fee_packages;
CREATE POLICY "amb_fee_packages_read" ON public.ambassador_fee_packages FOR SELECT TO authenticated USING (TRUE);
-- Sem política de escrita: só fn_admin_save_fee_package (SUPERADMIN).

INSERT INTO public.ambassador_fee_packages (id, name, monthly_fee, sort_order) VALUES
    ('pkg-basico', 'Plano Básico', 2500, 1),
    ('pkg-profissional', 'Plano Profissional', 3500, 2),
    ('pkg-empresarial', 'Plano Empresarial', 4500, 3),
    ('pkg-rede', 'Plano Rede Multi-Lojas', 6000, 4)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.fn_admin_save_fee_package(p_id TEXT, p_name TEXT, p_fee NUMERIC, p_active BOOLEAN DEFAULT TRUE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id TEXT := COALESCE(NULLIF(TRIM(p_id), ''), 'pkg-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 10));
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(p_name), '') IS NULL THEN RAISE EXCEPTION 'Nome do pacote é obrigatório.'; END IF;
    IF p_fee IS NULL OR p_fee < 0 THEN RAISE EXCEPTION 'Mensalidade inválida.'; END IF;
    INSERT INTO public.ambassador_fee_packages(id, name, monthly_fee, active, sort_order)
    VALUES (v_id, TRIM(p_name), p_fee, COALESCE(p_active, TRUE), COALESCE((SELECT MAX(sort_order) + 1 FROM public.ambassador_fee_packages), 1))
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, monthly_fee = EXCLUDED.monthly_fee, active = EXCLUDED.active, updated_at = NOW();
    PERFORM public.fn_amb_audit('FEE_PACKAGE_SAVED', NULL, NULL, NULL, jsonb_build_object('id', v_id, 'name', TRIM(p_name), 'fee', p_fee, 'active', COALESCE(p_active, TRUE)));
    RETURN jsonb_build_object('success', TRUE, 'id', v_id);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_save_fee_package(TEXT, TEXT, NUMERIC, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_save_fee_package(TEXT, TEXT, NUMERIC, BOOLEAN) TO authenticated;

-- ------------------------------------------------------------------------------
-- 4. VIGÊNCIA DE COMISSÕES (taxas futuras ficam agendadas; as passadas nunca são reescritas)
--    A comissão directa de cada loja já fica gravada na própria loja (commission_rate) e cada linha de
--    pagamento guarda a taxa usada, por isso alterar a taxa do embaixador só vale para o futuro.
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ambassador_rate_schedule (
    id BIGSERIAL PRIMARY KEY,
    ambassador_id TEXT NOT NULL REFERENCES public.ambassadors(id),
    direct_rate NUMERIC(5, 2) NOT NULL,
    indirect_rate NUMERIC(5, 2) NOT NULL DEFAULT 0,
    effective_from DATE NOT NULL,
    reason TEXT,
    created_by UUID DEFAULT auth.uid(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    applied_at TIMESTAMP WITH TIME ZONE
);
ALTER TABLE public.ambassador_rate_schedule ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "amb_rate_schedule_superadmin_select" ON public.ambassador_rate_schedule;
CREATE POLICY "amb_rate_schedule_superadmin_select" ON public.ambassador_rate_schedule FOR SELECT TO authenticated
USING (public.fn_is_superadmin());

-- Aplica as taxas cujo dia de vigência já chegou (chamada antes de cada comissão e ao abrir o painel).
CREATE OR REPLACE FUNCTION public.fn_apply_due_rate_changes()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r RECORD; n INT := 0; v public.ambassadors%ROWTYPE;
BEGIN
    FOR r IN SELECT * FROM public.ambassador_rate_schedule WHERE applied_at IS NULL AND effective_from <= CURRENT_DATE ORDER BY effective_from, id FOR UPDATE SKIP LOCKED LOOP
        SELECT * INTO v FROM public.ambassadors WHERE id = r.ambassador_id FOR UPDATE;
        IF v.id IS NOT NULL THEN
            IF v.commission_rate IS DISTINCT FROM r.direct_rate THEN
                INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value, changed_by)
                VALUES (v.id, 'commission_rate', v.commission_rate::TEXT, r.direct_rate::TEXT, r.created_by);
            END IF;
            IF COALESCE(v.indirect_commission_rate, 0) IS DISTINCT FROM r.indirect_rate THEN
                INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value, changed_by)
                VALUES (v.id, 'indirect_commission_rate', COALESCE(v.indirect_commission_rate, 0)::TEXT, r.indirect_rate::TEXT, r.created_by);
            END IF;
            UPDATE public.ambassadors
               SET commission_rate = r.direct_rate,
                   indirect_commission_rate = CASE WHEN COALESCE(is_super, FALSE) THEN r.indirect_rate ELSE 0 END
             WHERE id = v.id;
        END IF;
        UPDATE public.ambassador_rate_schedule SET applied_at = NOW() WHERE id = r.id;
        n := n + 1;
    END LOOP;
    RETURN n;
END; $$;
REVOKE ALL ON FUNCTION public.fn_apply_due_rate_changes() FROM PUBLIC, anon, authenticated;

-- SUPERADMIN: define as taxas com data de vigência. Hoje -> aplica já (reutiliza a função auditada da v6).
CREATE OR REPLACE FUNCTION public.fn_admin_schedule_ambassador_rates(
    p_ambassador_id TEXT, p_direct NUMERIC, p_indirect NUMERIC, p_effective_from DATE, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v public.ambassadors%ROWTYPE; v_from DATE := COALESCE(p_effective_from, CURRENT_DATE);
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF v_from < CURRENT_DATE THEN RAISE EXCEPTION 'A data de vigência não pode estar no passado (as comissões fechadas não são alteradas).'; END IF;
    IF p_direct IS NULL OR p_direct < 0 OR p_direct > 100 THEN RAISE EXCEPTION 'Comissão inválida (0 a 100).'; END IF;
    IF p_indirect IS NULL OR p_indirect < 0 OR p_indirect > 100 THEN RAISE EXCEPTION 'Comissão indirecta inválida (0 a 100).'; END IF;
    SELECT * INTO v FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL;
    IF v.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    IF p_indirect > 0 AND NOT COALESCE(v.is_super, FALSE) THEN RAISE EXCEPTION 'Só Super Embaixadores podem ter comissão indirecta.'; END IF;

    IF v_from = CURRENT_DATE THEN
        PERFORM public.fn_admin_set_ambassador_rates(v.id, p_direct, p_indirect);
    ELSE
        INSERT INTO public.ambassador_rate_schedule(ambassador_id, direct_rate, indirect_rate, effective_from, reason)
        VALUES (v.id, p_direct, p_indirect, v_from, p_reason);
    END IF;
    PERFORM public.fn_amb_audit('RATES_CHANGED', v.id, NULL, p_reason,
        jsonb_build_object('direct', p_direct, 'indirect', p_indirect, 'effective_from', v_from, 'previous_direct', v.commission_rate, 'previous_indirect', v.indirect_commission_rate));
    RETURN jsonb_build_object('success', TRUE, 'applied_now', v_from = CURRENT_DATE, 'effective_from', v_from);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_schedule_ambassador_rates(TEXT, NUMERIC, NUMERIC, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_schedule_ambassador_rates(TEXT, NUMERIC, NUMERIC, DATE, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 5. BLOQUEIO: precedência do SUPERADMIN e acesso por RPC
-- ------------------------------------------------------------------------------
-- fn_ambassador_resolve passa a recusar utilizadores bloqueados/eliminados SEMPRE (antes, a leitura
-- fn_ambassador_tracking chamava-a com p_require_active = FALSE e deixava um bloqueado ler dados).
CREATE OR REPLACE FUNCTION public.fn_ambassador_resolve(p_ambassador_id TEXT, p_require_active BOOLEAN DEFAULT TRUE)
RETURNS public.ambassadors
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
DECLARE
    v_amb public.ambassadors%ROWTYPE;
    v_role TEXT := public.get_auth_user_role();
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;

    IF p_ambassador_id IS NULL THEN
        SELECT * INTO v_amb FROM public.ambassadors WHERE user_id = auth.uid() LIMIT 1;
    ELSE
        SELECT * INTO v_amb FROM public.ambassadors WHERE id = p_ambassador_id;
    END IF;
    IF v_amb.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;

    IF v_role = 'SUPERADMIN' THEN RETURN v_amb; END IF;

    IF v_amb.user_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'Sem permissão para operar como este embaixador.';
    END IF;
    IF COALESCE(v_amb.status, 'ATIVO') <> 'ATIVO' OR v_amb.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'A sua conta está bloqueada. Contacte o administrador.';
    END IF;
    RETURN v_amb;
END; $$;
REVOKE ALL ON FUNCTION public.fn_ambassador_resolve(TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_resolve(TEXT, BOOLEAN) TO authenticated;

-- true se o utilizador autenticado é um embaixador activo (usada nas políticas RLS de leitura).
CREATE OR REPLACE FUNCTION public.fn_ambassador_is_active(p_ambassador_id TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM public.ambassadors a
                    WHERE a.id = p_ambassador_id AND a.user_id = auth.uid()
                      AND COALESCE(a.status, 'ATIVO') = 'ATIVO' AND a.deleted_at IS NULL);
$$;
REVOKE ALL ON FUNCTION public.fn_ambassador_is_active(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_is_active(TEXT) TO authenticated;

-- Leitura directa das tabelas (API REST) também só com a conta activa.
DROP POLICY IF EXISTS "ambassadors_self_read" ON public.ambassadors;
CREATE POLICY "ambassadors_self_read" ON public.ambassadors FOR SELECT TO authenticated
USING (user_id = auth.uid() AND COALESCE(status, 'ATIVO') = 'ATIVO' AND deleted_at IS NULL);

DROP POLICY IF EXISTS "ambassador_referred_stores_owner_select" ON public.ambassador_referred_stores;
CREATE POLICY "ambassador_referred_stores_owner_select" ON public.ambassador_referred_stores FOR SELECT TO authenticated
USING (public.fn_ambassador_is_active(ambassador_id));

DROP POLICY IF EXISTS "ambassador_payouts_owner_select" ON public.ambassador_payouts;
CREATE POLICY "ambassador_payouts_owner_select" ON public.ambassador_payouts FOR SELECT TO authenticated
USING (public.fn_ambassador_is_active(ambassador_id));

DROP POLICY IF EXISTS "amb_comm_payments_select" ON public.ambassador_commission_payments;
CREATE POLICY "amb_comm_payments_select" ON public.ambassador_commission_payments FOR SELECT TO authenticated
USING (public.fn_is_superadmin() OR public.fn_ambassador_is_active(ambassador_id));

-- Bloquear/desbloquear: só SUPERADMIN (reutiliza fn_admin_set_ambassador_status), com motivo e auditoria.
-- O Super Embaixador não tem NENHUMA função que desbloqueie contas; por isso o bloqueio do SUPERADMIN prevalece.
CREATE OR REPLACE FUNCTION public.fn_admin_block_ambassador(p_ambassador_id TEXT, p_status TEXT, p_reason TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_status TEXT := UPPER(TRIM(COALESCE(p_status, ''))); v_old TEXT;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF v_status <> 'ATIVO' AND NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'Indique o motivo do bloqueio.';
    END IF;
    SELECT COALESCE(status, 'ATIVO') INTO v_old FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL;
    IF v_old IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    PERFORM public.fn_admin_set_ambassador_status(p_ambassador_id, v_status);
    UPDATE public.ambassadors
       SET block_reason = CASE WHEN v_status = 'ATIVO' THEN NULL ELSE TRIM(p_reason) END,
           blocked_by_role = CASE WHEN v_status = 'ATIVO' THEN NULL ELSE 'SUPERADMIN' END
     WHERE id = p_ambassador_id;
    PERFORM public.fn_amb_audit(CASE WHEN v_status = 'ATIVO' THEN 'UNBLOCKED' ELSE 'BLOCKED' END, p_ambassador_id, NULL, p_reason,
        jsonb_build_object('from', v_old, 'to', v_status));
    RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_block_ambassador(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_block_ambassador(TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 6. SUPERADMIN: CRIAR / PROMOVER / DESPROMOVER / TRANSFERIR / EDITAR / ELIMINAR
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_amb_code(p_name TEXT) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v TEXT := 'GEF-' || UPPER(REGEXP_REPLACE(SPLIT_PART(TRIM(p_name), ' ', 1), '[^A-Za-z0-9]', '', 'g')) || '-' || EXTRACT(YEAR FROM NOW())::INT;
BEGIN
    IF EXISTS (SELECT 1 FROM public.ambassadors WHERE referral_code = v) THEN v := v || '-' || UPPER(SUBSTR(MD5(RANDOM()::TEXT), 1, 4)); END IF;
    RETURN v;
END; $$;
REVOKE ALL ON FUNCTION public.fn_amb_code(TEXT) FROM PUBLIC, anon, authenticated;

-- 6.1 Criar Embaixador (EMBAIXADOR) ou Super Embaixador (SUPER_EMBAIXADOR) — idioma e moeda OBRIGATÓRIOS.
--     Tudo numa só transacção (registo + acesso de login opcional + auditoria).
CREATE OR REPLACE FUNCTION public.fn_admin_create_ambassador_profile(
    p_kind TEXT, p_name TEXT, p_phone TEXT, p_whatsapp TEXT, p_email TEXT, p_pix_mpesa TEXT,
    p_language TEXT, p_currency TEXT,
    p_commission_rate NUMERIC, p_indirect_rate NUMERIC, p_effective_from DATE, p_parent_id TEXT,
    p_country TEXT, p_province TEXT, p_district TEXT, p_city TEXT, p_neighborhood TEXT, p_geo_description TEXT,
    p_login_email TEXT DEFAULT NULL, p_login_password TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, auth, pg_temp AS $$
DECLARE
    v_kind TEXT := UPPER(TRIM(COALESCE(p_kind, '')));
    v_super BOOLEAN; v_id TEXT; v_code TEXT; v_uid UUID; v_par public.ambassadors%ROWTYPE;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF v_kind NOT IN ('EMBAIXADOR', 'SUPER_EMBAIXADOR') THEN RAISE EXCEPTION 'Perfil inválido.'; END IF;
    v_super := (v_kind = 'SUPER_EMBAIXADOR');
    IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome é obrigatório.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_phone, '')), '') IS NULL THEN RAISE EXCEPTION 'Telefone é obrigatório.'; END IF;
    IF p_language IS NULL OR NOT public.fn_valid_language(p_language) THEN RAISE EXCEPTION 'Seleccione o idioma (obrigatório).'; END IF;
    IF p_currency IS NULL OR NOT public.fn_valid_currency(p_currency) THEN RAISE EXCEPTION 'Seleccione a moeda (obrigatório).'; END IF;
    IF p_commission_rate IS NULL OR p_commission_rate < 0 OR p_commission_rate > 100 THEN RAISE EXCEPTION 'Comissão inválida (0 a 100).'; END IF;
    IF COALESCE(p_indirect_rate, 0) < 0 OR COALESCE(p_indirect_rate, 0) > 100 THEN RAISE EXCEPTION 'Comissão indirecta inválida (0 a 100).'; END IF;
    IF COALESCE(p_indirect_rate, 0) > 0 AND NOT v_super THEN RAISE EXCEPTION 'Só Super Embaixadores têm comissão indirecta.'; END IF;
    IF v_super AND NULLIF(TRIM(COALESCE(p_parent_id, '')), '') IS NOT NULL THEN RAISE EXCEPTION 'Um Super Embaixador não pode ter Super Embaixador acima.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_parent_id, '')), '') IS NOT NULL THEN
        SELECT * INTO v_par FROM public.ambassadors WHERE id = p_parent_id AND deleted_at IS NULL;
        IF v_par.id IS NULL OR NOT COALESCE(v_par.is_super, FALSE) OR COALESCE(v_par.status, 'ATIVO') <> 'ATIVO' THEN
            RAISE EXCEPTION 'O Super Embaixador escolhido não existe, não está activo ou não é Super Embaixador.';
        END IF;
    END IF;
    IF (NULLIF(TRIM(COALESCE(p_login_email, '')), '') IS NULL) <> (NULLIF(p_login_password, '') IS NULL) THEN
        RAISE EXCEPTION 'Para criar o acesso, indique email e senha.';
    END IF;

    v_id := 'amb-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_code := public.fn_amb_code(p_name);

    INSERT INTO public.ambassadors (id, name, phone, whatsapp, email, pix_mpesa, referral_code, commission_rate, indirect_commission_rate,
                                    is_super, parent_ambassador_id, status, active, language, currency, effective_from,
                                    geo_country, geo_province, geo_district, geo_city, geo_neighborhood, geo_description)
    VALUES (v_id, TRIM(p_name), TRIM(p_phone), NULLIF(TRIM(COALESCE(p_whatsapp, '')), ''), NULLIF(TRIM(COALESCE(p_email, '')), ''),
            COALESCE(NULLIF(TRIM(COALESCE(p_pix_mpesa, '')), ''), 'M-Pesa ' || TRIM(p_phone)), v_code, p_commission_rate,
            CASE WHEN v_super THEN COALESCE(p_indirect_rate, 0) ELSE 0 END,
            v_super, NULLIF(TRIM(COALESCE(p_parent_id, '')), ''), 'ATIVO', TRUE, p_language, p_currency, COALESCE(p_effective_from, CURRENT_DATE),
            NULLIF(TRIM(COALESCE(p_country, '')), ''), NULLIF(TRIM(COALESCE(p_province, '')), ''), NULLIF(TRIM(COALESCE(p_district, '')), ''),
            NULLIF(TRIM(COALESCE(p_city, '')), ''), NULLIF(TRIM(COALESCE(p_neighborhood, '')), ''), NULLIF(TRIM(COALESCE(p_geo_description, '')), ''));

    IF NULLIF(TRIM(COALESCE(p_login_email, '')), '') IS NOT NULL THEN
        v_uid := public.fn_internal_create_store_user(p_login_email, p_login_password, TRIM(p_name), 'EMBAIXADOR', NULL);
        UPDATE public.ambassadors SET user_id = v_uid WHERE id = v_id;
    END IF;

    INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value)
    VALUES (v_id, 'commission_rate', NULL, p_commission_rate::TEXT);
    PERFORM public.fn_amb_audit('CREATED', v_id, NULL, NULL,
        jsonb_build_object('kind', v_kind, 'language', p_language, 'currency', p_currency, 'commission', p_commission_rate,
                           'indirect', COALESCE(p_indirect_rate, 0), 'parent', p_parent_id, 'login_created', v_uid IS NOT NULL));
    RETURN jsonb_build_object('success', TRUE, 'ambassador_id', v_id, 'referral_code', v_code, 'user_id', v_uid);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_create_ambassador_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_create_ambassador_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- Backend também recusa o caminho antigo de criação sem idioma/moeda (trigger só no INSERT).
CREATE OR REPLACE FUNCTION public.fn_ambassadors_require_prefs()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.language IS NULL OR NOT public.fn_valid_language(NEW.language) THEN RAISE EXCEPTION 'Seleccione o idioma (obrigatório).'; END IF;
    IF NEW.currency IS NULL OR NOT public.fn_valid_currency(NEW.currency) THEN RAISE EXCEPTION 'Seleccione a moeda (obrigatório).'; END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_ambassadors_require_prefs ON public.ambassadors;
CREATE TRIGGER trg_ambassadors_require_prefs BEFORE INSERT ON public.ambassadors
    FOR EACH ROW EXECUTE FUNCTION public.fn_ambassadors_require_prefs();

-- 6.2 Pré-visualização das consequências (só leitura) — usada antes de confirmar qualquer operação.
CREATE OR REPLACE FUNCTION public.fn_admin_preview_ambassador_change(p_ambassador_id TEXT, p_action TEXT, p_target_id TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    a public.ambassadors%ROWTYPE; par public.ambassadors%ROWTYPE; tgt public.ambassadors%ROWTYPE;
    v_act TEXT := UPPER(TRIM(COALESCE(p_action, '')));
    v_children JSONB; v_stores JSONB; v_errors JSONB := '[]'::JSONB; v_warn JSONB := '[]'::JSONB;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    SELECT * INTO a FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL;
    IF a.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    IF a.parent_ambassador_id IS NOT NULL THEN SELECT * INTO par FROM public.ambassadors WHERE id = a.parent_ambassador_id; END IF;
    IF p_target_id IS NOT NULL THEN SELECT * INTO tgt FROM public.ambassadors WHERE id = p_target_id AND deleted_at IS NULL; END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'status', COALESCE(c.status, 'ATIVO'),
             'stores', (SELECT COUNT(*) FROM public.ambassador_referred_stores r WHERE r.ambassador_id = c.id))), '[]'::JSONB)
      INTO v_children FROM public.ambassadors c WHERE c.parent_ambassador_id = a.id AND c.deleted_at IS NULL;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'monthly_fee', r.monthly_fee, 'commission_rate', r.commission_rate)), '[]'::JSONB)
      INTO v_stores FROM public.ambassador_referred_stores r WHERE r.ambassador_id = a.id;

    IF v_act = 'PROMOTE' THEN
        IF COALESCE(a.is_super, FALSE) THEN v_errors := v_errors || to_jsonb('Já é Super Embaixador.'::TEXT); END IF;
        IF a.parent_ambassador_id IS NOT NULL THEN
            v_warn := v_warn || to_jsonb(('Está na rede de «' || par.name || '». Ao promover sai dessa rede (fica registado no histórico). As lojas e comissões antigas não mudam.')::TEXT);
        END IF;
    ELSIF v_act = 'DEMOTE' THEN
        IF NOT COALESCE(a.is_super, FALSE) THEN v_errors := v_errors || to_jsonb('Não é Super Embaixador.'::TEXT); END IF;
        IF jsonb_array_length(v_children) > 0 AND tgt.id IS NULL THEN
            v_errors := v_errors || to_jsonb('Tem embaixadores na rede: escolha o Super Embaixador de destino para os receber.'::TEXT);
        END IF;
        IF tgt.id IS NOT NULL AND (NOT COALESCE(tgt.is_super, FALSE) OR tgt.id = a.id) THEN
            v_errors := v_errors || to_jsonb('O destino tem de ser outro Super Embaixador.'::TEXT);
        END IF;
        v_warn := v_warn || to_jsonb('A comissão indirecta passa a 0. Os pagamentos e comissões já registados mantêm-se.'::TEXT);
    ELSIF v_act = 'TRANSFER' THEN
        IF COALESCE(a.is_super, FALSE) THEN v_errors := v_errors || to_jsonb('Um Super Embaixador não é transferido: use a despromoção.'::TEXT); END IF;
        IF tgt.id IS NULL OR NOT COALESCE(tgt.is_super, FALSE) OR COALESCE(tgt.status, 'ATIVO') <> 'ATIVO' THEN
            v_errors := v_errors || to_jsonb('Destino inválido: tem de ser um Super Embaixador activo.'::TEXT);
        END IF;
        IF tgt.id IS NOT NULL AND tgt.id = a.parent_ambassador_id THEN v_errors := v_errors || to_jsonb('Já pertence a este Super Embaixador.'::TEXT); END IF;
        v_warn := v_warn || to_jsonb('A comissão indirecta dos pagamentos futuros vai para o novo Super Embaixador; os pagamentos já registados ficam com o anterior.'::TEXT);
    ELSIF v_act = 'DELETE' THEN
        IF (jsonb_array_length(v_children) > 0 OR jsonb_array_length(v_stores) > 0) AND tgt.id IS NULL THEN
            v_errors := v_errors || to_jsonb('Tem embaixadores/lojas vinculados: escolha o destino que os recebe.'::TEXT);
        END IF;
        v_warn := v_warn || to_jsonb('Eliminação lógica: nada é apagado; lojas, pagamentos e comissões mantêm-se no histórico.'::TEXT);
    ELSE
        RAISE EXCEPTION 'Acção inválida.';
    END IF;

    RETURN jsonb_build_object('ambassador', jsonb_build_object('id', a.id, 'name', a.name, 'is_super', COALESCE(a.is_super, FALSE), 'status', COALESCE(a.status, 'ATIVO'),
                'pending_commissions', COALESCE(a.pending_commissions, 0)),
        'current_parent', CASE WHEN par.id IS NULL THEN NULL ELSE jsonb_build_object('id', par.id, 'name', par.name, 'phone', par.phone) END,
        'target', CASE WHEN tgt.id IS NULL THEN NULL ELSE jsonb_build_object('id', tgt.id, 'name', tgt.name, 'is_super', COALESCE(tgt.is_super, FALSE)) END,
        'network_ambassadors', v_children, 'direct_stores', v_stores, 'errors', v_errors, 'warnings', v_warn, 'can_proceed', jsonb_array_length(v_errors) = 0);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_preview_ambassador_change(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_preview_ambassador_change(TEXT, TEXT, TEXT) TO authenticated;

-- 6.3 Promover Embaixador -> Super Embaixador
CREATE OR REPLACE FUNCTION public.fn_admin_promote_ambassador(p_ambassador_id TEXT, p_reason TEXT, p_indirect_rate NUMERIC DEFAULT 0, p_effective_from DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.ambassadors%ROWTYPE; v_from DATE := COALESCE(p_effective_from, CURRENT_DATE);
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN RAISE EXCEPTION 'Indique o motivo.'; END IF;
    IF COALESCE(p_indirect_rate, 0) < 0 OR COALESCE(p_indirect_rate, 0) > 100 THEN RAISE EXCEPTION 'Comissão indirecta inválida (0 a 100).'; END IF;
    SELECT * INTO a FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL FOR UPDATE;
    IF a.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    IF COALESCE(a.is_super, FALSE) THEN RAISE EXCEPTION 'Já é Super Embaixador.'; END IF;
    IF COALESCE(a.status, 'ATIVO') <> 'ATIVO' THEN RAISE EXCEPTION 'Só se promove um embaixador activo.'; END IF;

    IF a.parent_ambassador_id IS NOT NULL THEN
        INSERT INTO public.ambassador_transfers(kind, subject_id, from_id, to_id, reason, effective_date, details)
        VALUES ('AMBASSADOR', a.id, a.parent_ambassador_id, NULL, 'Promoção a Super Embaixador: ' || TRIM(p_reason), v_from, jsonb_build_object('operation', 'PROMOTE'));
    END IF;
    UPDATE public.ambassadors
       SET is_super = TRUE, parent_ambassador_id = NULL, effective_from = v_from,
           indirect_commission_rate = COALESCE(p_indirect_rate, 0)
     WHERE id = a.id;
    INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value) VALUES (a.id, 'is_super', 'false', 'true');
    IF a.parent_ambassador_id IS NOT NULL THEN
        INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value) VALUES (a.id, 'parent_ambassador_id', a.parent_ambassador_id, NULL);
    END IF;
    PERFORM public.fn_amb_audit('PROMOTED', a.id, NULL, p_reason, jsonb_build_object('previous_parent', a.parent_ambassador_id, 'indirect_rate', COALESCE(p_indirect_rate, 0), 'effective_from', v_from));
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_promote_ambassador(TEXT, TEXT, NUMERIC, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_promote_ambassador(TEXT, TEXT, NUMERIC, DATE) TO authenticated;

-- 6.4 Despromover Super Embaixador -> Embaixador (a rede é transferida explicitamente, nunca "ao acaso")
CREATE OR REPLACE FUNCTION public.fn_admin_demote_ambassador(p_ambassador_id TEXT, p_reason TEXT, p_network_target_id TEXT DEFAULT NULL, p_new_parent_id TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.ambassadors%ROWTYPE; tgt public.ambassadors%ROWTYPE; np public.ambassadors%ROWTYPE; c RECORD; v_n INT := 0;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN RAISE EXCEPTION 'Indique o motivo.'; END IF;
    SELECT * INTO a FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL FOR UPDATE;
    IF a.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    IF NOT COALESCE(a.is_super, FALSE) THEN RAISE EXCEPTION 'Não é Super Embaixador.'; END IF;

    IF EXISTS (SELECT 1 FROM public.ambassadors WHERE parent_ambassador_id = a.id AND deleted_at IS NULL) THEN
        SELECT * INTO tgt FROM public.ambassadors WHERE id = p_network_target_id AND deleted_at IS NULL;
        IF tgt.id IS NULL OR tgt.id = a.id OR NOT COALESCE(tgt.is_super, FALSE) OR COALESCE(tgt.status, 'ATIVO') <> 'ATIVO' THEN
            RAISE EXCEPTION 'Tem embaixadores na rede: indique um Super Embaixador activo de destino.';
        END IF;
        FOR c IN SELECT id FROM public.ambassadors WHERE parent_ambassador_id = a.id AND deleted_at IS NULL FOR UPDATE LOOP
            UPDATE public.ambassadors SET parent_ambassador_id = tgt.id WHERE id = c.id;
            INSERT INTO public.ambassador_transfers(kind, subject_id, from_id, to_id, reason, effective_date, details)
            VALUES ('AMBASSADOR', c.id, a.id, tgt.id, 'Despromoção do Super Embaixador: ' || TRIM(p_reason), CURRENT_DATE, jsonb_build_object('operation', 'DEMOTE'));
            INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value) VALUES (c.id, 'parent_ambassador_id', a.id, tgt.id);
            v_n := v_n + 1;
        END LOOP;
    END IF;

    IF NULLIF(TRIM(COALESCE(p_new_parent_id, '')), '') IS NOT NULL THEN
        SELECT * INTO np FROM public.ambassadors WHERE id = p_new_parent_id AND deleted_at IS NULL;
        IF np.id IS NULL OR np.id = a.id OR NOT COALESCE(np.is_super, FALSE) OR COALESCE(np.status, 'ATIVO') <> 'ATIVO' THEN
            RAISE EXCEPTION 'O novo Super Embaixador responsável é inválido.';
        END IF;
    END IF;

    UPDATE public.ambassadors SET is_super = FALSE, indirect_commission_rate = 0, parent_ambassador_id = NULLIF(TRIM(COALESCE(p_new_parent_id, '')), '') WHERE id = a.id;
    INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value) VALUES (a.id, 'is_super', 'true', 'false');
    IF COALESCE(a.indirect_commission_rate, 0) <> 0 THEN
        INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value) VALUES (a.id, 'indirect_commission_rate', a.indirect_commission_rate::TEXT, '0');
    END IF;
    PERFORM public.fn_amb_audit('DEMOTED', a.id, NULL, p_reason, jsonb_build_object('network_moved_to', p_network_target_id, 'ambassadors_moved', v_n, 'new_parent', p_new_parent_id));
    RETURN jsonb_build_object('success', TRUE, 'ambassadors_moved', v_n);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_demote_ambassador(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_demote_ambassador(TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 6.5 Transferir Embaixador entre Super Embaixadores
CREATE OR REPLACE FUNCTION public.fn_admin_transfer_ambassador(p_ambassador_id TEXT, p_new_parent_id TEXT, p_reason TEXT, p_effective_date DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.ambassadors%ROWTYPE; t public.ambassadors%ROWTYPE; v_from DATE := COALESCE(p_effective_date, CURRENT_DATE);
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN RAISE EXCEPTION 'Indique o motivo da transferência.'; END IF;
    IF v_from > CURRENT_DATE THEN RAISE EXCEPTION 'A data efectiva não pode ser futura.'; END IF;
    SELECT * INTO a FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL FOR UPDATE;
    IF a.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    IF COALESCE(a.is_super, FALSE) THEN RAISE EXCEPTION 'Um Super Embaixador não é transferido: use a despromoção.'; END IF;
    SELECT * INTO t FROM public.ambassadors WHERE id = p_new_parent_id AND deleted_at IS NULL;
    IF t.id IS NULL OR NOT COALESCE(t.is_super, FALSE) OR COALESCE(t.status, 'ATIVO') <> 'ATIVO' THEN
        RAISE EXCEPTION 'Destino inválido: tem de ser um Super Embaixador activo.';
    END IF;
    IF a.parent_ambassador_id IS NOT DISTINCT FROM t.id THEN RAISE EXCEPTION 'O embaixador já pertence a este Super Embaixador.'; END IF;

    UPDATE public.ambassadors SET parent_ambassador_id = t.id WHERE id = a.id;
    INSERT INTO public.ambassador_transfers(kind, subject_id, from_id, to_id, reason, effective_date, details)
    VALUES ('AMBASSADOR', a.id, a.parent_ambassador_id, t.id, TRIM(p_reason), v_from, jsonb_build_object('operation', 'TRANSFER'));
    INSERT INTO public.ambassador_rate_audit(ambassador_id, field, old_value, new_value) VALUES (a.id, 'parent_ambassador_id', a.parent_ambassador_id, t.id);
    PERFORM public.fn_amb_audit('AMBASSADOR_TRANSFERRED', a.id, NULL, p_reason, jsonb_build_object('from', a.parent_ambassador_id, 'to', t.id, 'effective_date', v_from));
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_transfer_ambassador(TEXT, TEXT, TEXT, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_transfer_ambassador(TEXT, TEXT, TEXT, DATE) TO authenticated;

-- 6.6 Transferir loja entre Embaixadores. Os pagamentos/comissões históricos ficam com quem os gerou
--     (ambassador_commission_payments.ambassador_id não é tocado); só os pagamentos futuros vão para o novo responsável.
CREATE OR REPLACE FUNCTION public.fn_admin_preview_store_transfer(p_ref_store_id TEXT, p_target_id TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.ambassador_referred_stores%ROWTYPE; o public.ambassadors%ROWTYPE; t public.ambassadors%ROWTYPE;
        v_errors JSONB := '[]'::JSONB; v_hist INT; v_pend NUMERIC;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    SELECT * INTO r FROM public.ambassador_referred_stores WHERE id = p_ref_store_id;
    IF r.id IS NULL THEN RAISE EXCEPTION 'Loja indicada não encontrada.'; END IF;
    SELECT * INTO o FROM public.ambassadors WHERE id = r.ambassador_id;
    SELECT * INTO t FROM public.ambassadors WHERE id = p_target_id AND deleted_at IS NULL;
    IF t.id IS NULL OR COALESCE(t.status, 'ATIVO') <> 'ATIVO' THEN v_errors := v_errors || to_jsonb('Destino inválido: tem de ser um embaixador activo.'::TEXT); END IF;
    IF t.id IS NOT NULL AND t.id = r.ambassador_id THEN v_errors := v_errors || to_jsonb('A loja já pertence a este embaixador.'::TEXT); END IF;
    SELECT COUNT(*), COALESCE(SUM(commission_amount), 0) INTO v_hist, v_pend FROM public.ambassador_commission_payments WHERE referred_store_id = r.id;
    RETURN jsonb_build_object('store', jsonb_build_object('id', r.id, 'name', r.name, 'monthly_fee', r.monthly_fee, 'commission_rate', r.commission_rate),
        'from', jsonb_build_object('id', o.id, 'name', o.name, 'is_super', COALESCE(o.is_super, FALSE), 'parent_id', o.parent_ambassador_id),
        'to', CASE WHEN t.id IS NULL THEN NULL ELSE jsonb_build_object('id', t.id, 'name', t.name, 'is_super', COALESCE(t.is_super, FALSE), 'parent_id', t.parent_ambassador_id, 'commission_rate', t.commission_rate) END,
        'historical_payments', v_hist, 'historical_commission', v_pend,
        'warnings', jsonb_build_array('Os pagamentos e comissões já registados ficam com o embaixador anterior.',
                                       'Os pagamentos futuros passam a gerar comissão para o novo embaixador (e para o Super Embaixador dele, se existir).'),
        'errors', v_errors, 'can_proceed', jsonb_array_length(v_errors) = 0);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_preview_store_transfer(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_preview_store_transfer(TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_transfer_store(p_ref_store_id TEXT, p_new_ambassador_id TEXT, p_reason TEXT, p_apply_new_rate BOOLEAN DEFAULT TRUE)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r public.ambassador_referred_stores%ROWTYPE; t public.ambassadors%ROWTYPE; v_new_rate NUMERIC;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN RAISE EXCEPTION 'Indique o motivo da transferência.'; END IF;
    SELECT * INTO r FROM public.ambassador_referred_stores WHERE id = p_ref_store_id FOR UPDATE;
    IF r.id IS NULL THEN RAISE EXCEPTION 'Loja indicada não encontrada.'; END IF;
    SELECT * INTO t FROM public.ambassadors WHERE id = p_new_ambassador_id AND deleted_at IS NULL;
    IF t.id IS NULL OR COALESCE(t.status, 'ATIVO') <> 'ATIVO' THEN RAISE EXCEPTION 'Destino inválido: tem de ser um embaixador activo.'; END IF;
    IF t.id = r.ambassador_id THEN RAISE EXCEPTION 'A loja já pertence a este embaixador.'; END IF;

    v_new_rate := CASE WHEN COALESCE(p_apply_new_rate, TRUE) THEN COALESCE(t.commission_rate, r.commission_rate) ELSE r.commission_rate END;
    UPDATE public.ambassador_referred_stores SET ambassador_id = t.id, commission_rate = v_new_rate WHERE id = r.id;
    INSERT INTO public.ambassador_transfers(kind, subject_id, from_id, to_id, reason, effective_date, details)
    VALUES ('STORE', r.id, r.ambassador_id, t.id, TRIM(p_reason), CURRENT_DATE,
            jsonb_build_object('old_rate', r.commission_rate, 'new_rate', v_new_rate, 'store_id', r.store_id));
    PERFORM public.fn_amb_audit('STORE_TRANSFERRED', t.id, r.id, p_reason,
        jsonb_build_object('from', r.ambassador_id, 'to', t.id, 'old_rate', r.commission_rate, 'new_rate', v_new_rate));
    RETURN jsonb_build_object('success', TRUE, 'new_rate', v_new_rate);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_transfer_store(TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_transfer_store(TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;

-- 6.7 Editar contactos, área geográfica, idioma e moeda (área não mexe em vínculos nem finanças)
CREATE OR REPLACE FUNCTION public.fn_admin_set_ambassador_profile(
    p_ambassador_id TEXT, p_name TEXT, p_phone TEXT, p_whatsapp TEXT, p_email TEXT,
    p_language TEXT, p_currency TEXT,
    p_country TEXT, p_province TEXT, p_district TEXT, p_city TEXT, p_neighborhood TEXT, p_geo_description TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.ambassadors%ROWTYPE;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome é obrigatório.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_phone, '')), '') IS NULL THEN RAISE EXCEPTION 'Telefone é obrigatório.'; END IF;
    IF p_language IS NULL OR NOT public.fn_valid_language(p_language) THEN RAISE EXCEPTION 'Seleccione o idioma (obrigatório).'; END IF;
    IF p_currency IS NULL OR NOT public.fn_valid_currency(p_currency) THEN RAISE EXCEPTION 'Seleccione a moeda (obrigatório).'; END IF;
    SELECT * INTO a FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL FOR UPDATE;
    IF a.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;

    UPDATE public.ambassadors
       SET name = TRIM(p_name), phone = TRIM(p_phone),
           whatsapp = NULLIF(TRIM(COALESCE(p_whatsapp, '')), ''), email = NULLIF(TRIM(COALESCE(p_email, '')), ''),
           language = p_language, currency = p_currency,
           geo_country = NULLIF(TRIM(COALESCE(p_country, '')), ''), geo_province = NULLIF(TRIM(COALESCE(p_province, '')), ''),
           geo_district = NULLIF(TRIM(COALESCE(p_district, '')), ''), geo_city = NULLIF(TRIM(COALESCE(p_city, '')), ''),
           geo_neighborhood = NULLIF(TRIM(COALESCE(p_neighborhood, '')), ''), geo_description = NULLIF(TRIM(COALESCE(p_geo_description, '')), '')
     WHERE id = a.id;
    -- Só a preferência de apresentação muda; registos financeiros históricos não são tocados.
    PERFORM public.fn_amb_audit('PROFILE_EDITED', a.id, NULL, p_reason,
        jsonb_build_object('old', jsonb_build_object('name', a.name, 'phone', a.phone, 'language', a.language, 'currency', a.currency,
                                                      'country', a.geo_country, 'province', a.geo_province, 'district', a.geo_district, 'city', a.geo_city, 'neighborhood', a.geo_neighborhood),
                           'new', jsonb_build_object('name', TRIM(p_name), 'phone', TRIM(p_phone), 'language', p_language, 'currency', p_currency,
                                                      'country', p_country, 'province', p_province, 'district', p_district, 'city', p_city, 'neighborhood', p_neighborhood)));
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_set_ambassador_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_set_ambassador_profile(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- 6.8 Eliminação lógica (nada é apagado; vínculos passam, com registo, para o destino escolhido)
CREATE OR REPLACE FUNCTION public.fn_admin_soft_delete_ambassador(p_ambassador_id TEXT, p_reason TEXT, p_target_id TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a public.ambassadors%ROWTYPE; t public.ambassadors%ROWTYPE; c RECORD; v_n INT := 0; v_s INT := 0; v_has BOOLEAN;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL THEN RAISE EXCEPTION 'Indique o motivo.'; END IF;
    SELECT * INTO a FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL FOR UPDATE;
    IF a.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;

    v_has := EXISTS (SELECT 1 FROM public.ambassadors WHERE parent_ambassador_id = a.id AND deleted_at IS NULL)
          OR EXISTS (SELECT 1 FROM public.ambassador_referred_stores WHERE ambassador_id = a.id);
    IF v_has THEN
        SELECT * INTO t FROM public.ambassadors WHERE id = p_target_id AND deleted_at IS NULL;
        IF t.id IS NULL OR t.id = a.id OR COALESCE(t.status, 'ATIVO') <> 'ATIVO' THEN RAISE EXCEPTION 'Escolha um destino activo para receber os vínculos.'; END IF;
        -- Embaixadores da rede só podem ir para outro Super Embaixador.
        IF EXISTS (SELECT 1 FROM public.ambassadors WHERE parent_ambassador_id = a.id AND deleted_at IS NULL) AND NOT COALESCE(t.is_super, FALSE) THEN
            RAISE EXCEPTION 'A rede só pode ser transferida para um Super Embaixador.';
        END IF;
        FOR c IN SELECT id FROM public.ambassadors WHERE parent_ambassador_id = a.id AND deleted_at IS NULL FOR UPDATE LOOP
            UPDATE public.ambassadors SET parent_ambassador_id = t.id WHERE id = c.id;
            INSERT INTO public.ambassador_transfers(kind, subject_id, from_id, to_id, reason, details)
            VALUES ('AMBASSADOR', c.id, a.id, t.id, 'Eliminação do responsável: ' || TRIM(p_reason), jsonb_build_object('operation', 'DELETE'));
            v_n := v_n + 1;
        END LOOP;
        FOR c IN SELECT id, commission_rate FROM public.ambassador_referred_stores WHERE ambassador_id = a.id FOR UPDATE LOOP
            UPDATE public.ambassador_referred_stores SET ambassador_id = t.id WHERE id = c.id;
            INSERT INTO public.ambassador_transfers(kind, subject_id, from_id, to_id, reason, details)
            VALUES ('STORE', c.id, a.id, t.id, 'Eliminação do responsável: ' || TRIM(p_reason), jsonb_build_object('operation', 'DELETE', 'rate_kept', c.commission_rate));
            v_s := v_s + 1;
        END LOOP;
    END IF;

    UPDATE public.ambassadors
       SET deleted_at = NOW(), deleted_by = auth.uid(), status = 'DESATIVADO', active = FALSE,
           parent_ambassador_id = NULL, block_reason = 'Conta eliminada.', blocked_by_role = 'SUPERADMIN'
     WHERE id = a.id;
    IF a.user_id IS NOT NULL THEN UPDATE public.profiles SET active = FALSE, updated_at = NOW() WHERE id = a.user_id AND role = 'EMBAIXADOR'; END IF;
    PERFORM public.fn_amb_audit('DELETED', a.id, NULL, p_reason, jsonb_build_object('target', p_target_id, 'ambassadors_moved', v_n, 'stores_moved', v_s));
    RETURN jsonb_build_object('success', TRUE, 'ambassadors_moved', v_n, 'stores_moved', v_s);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_soft_delete_ambassador(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_soft_delete_ambassador(TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 7. SUPER EMBAIXADOR
-- ------------------------------------------------------------------------------
-- Rede própria (só leitura). Mostra comissões AUTORIZADAS = as dele; nunca as taxas/valores dos embaixadores da rede.
CREATE OR REPLACE FUNCTION public.fn_super_network()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE me public.ambassadors%ROWTYPE; v_out JSONB;
BEGIN
    me := public.fn_ambassador_resolve(NULL, TRUE);
    IF NOT COALESCE(me.is_super, FALSE) THEN RAISE EXCEPTION 'Reservado a Super Embaixadores.'; END IF;

    SELECT jsonb_build_object(
        'ambassadors', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'id', c.id, 'name', c.name, 'phone', c.phone, 'whatsapp', c.whatsapp,
                'status', COALESCE(c.status, 'ATIVO'),
                'area', concat_ws(', ', c.geo_neighborhood, c.geo_city, c.geo_district, c.geo_province, c.geo_country),
                'stores', (SELECT COUNT(*) FROM public.ambassador_referred_stores r WHERE r.ambassador_id = c.id)) ORDER BY c.name)
              FROM public.ambassadors c WHERE c.parent_ambassador_id = me.id AND c.deleted_at IS NULL), '[]'::JSONB),
        'stores', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'id', r.id, 'name', r.name, 'owner_name', r.owner_name, 'phone', r.phone, 'city', r.city,
                'origin', CASE WHEN r.ambassador_id = me.id THEN 'DIRECTA' ELSE 'INDIRECTA' END,
                'ambassador_id', r.ambassador_id, 'ambassador_name', o.name,
                'monthly_fee', COALESCE(s.valor_mensalidade, r.monthly_fee, 0),
                'subscription_end', s.data_fim_teste,
                'days_remaining', (s.data_fim_teste - CURRENT_DATE),
                'status', CASE WHEN s.id IS NULL THEN 'SEM_LOJA' WHEN s.acesso_ativo = FALSE THEN 'BLOQUEADA'
                               WHEN s.data_fim_teste < CURRENT_DATE THEN 'EXPIRADA' WHEN r.last_payment_date IS NULL THEN 'EM_TESTE' ELSE 'ATIVA' END,
                'last_payment_date', r.last_payment_date) ORDER BY r.created_at DESC)
              FROM public.ambassador_referred_stores r
              JOIN public.ambassadors o ON o.id = r.ambassador_id
              LEFT JOIN public.stores s ON s.id = COALESCE(r.store_id, r.id)
             WHERE r.ambassador_id = me.id OR o.parent_ambassador_id = me.id), '[]'::JSONB),
        -- receita de mensalidades da rede (uma linha DIRECT por pagamento de loja; INDIRECT repete valor e nunca entra)
        'network_revenue', COALESCE((SELECT SUM(p.payment_amount) FROM public.ambassador_commission_payments p
                 JOIN public.ambassadors o ON o.id = p.ambassador_id
                WHERE p.kind = 'DIRECT' AND (o.id = me.id OR o.parent_ambassador_id = me.id)), 0),
        'commission_direct', COALESCE((SELECT SUM(commission_amount) FROM public.ambassador_commission_payments WHERE ambassador_id = me.id AND kind = 'DIRECT'), 0),
        'commission_indirect', COALESCE((SELECT SUM(commission_amount) FROM public.ambassador_commission_payments WHERE ambassador_id = me.id AND kind = 'INDIRECT'), 0),
        'commission_pending', COALESCE(me.pending_commissions, 0),
        'commission_paid', COALESCE((SELECT SUM(amount) FROM public.ambassador_payouts WHERE ambassador_id = me.id), 0)
    ) INTO v_out;
    RETURN v_out;
END; $$;
REVOKE ALL ON FUNCTION public.fn_super_network() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_super_network() TO authenticated;

-- Super Embaixador cadastra Embaixador normal NA SUA REDE. Comissão fica no valor por omissão da tabela
-- (10%) até o Super Administrador a definir; idioma/moeda herdados do Super Embaixador. Nunca altera comissões.
CREATE OR REPLACE FUNCTION public.fn_super_create_ambassador(
    p_name TEXT, p_phone TEXT, p_whatsapp TEXT, p_email TEXT, p_pix_mpesa TEXT,
    p_login_email TEXT DEFAULT NULL, p_login_password TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, auth, pg_temp AS $$
DECLARE me public.ambassadors%ROWTYPE; v_id TEXT; v_code TEXT; v_uid UUID;
BEGIN
    me := public.fn_ambassador_resolve(NULL, TRUE);
    IF NOT COALESCE(me.is_super, FALSE) THEN RAISE EXCEPTION 'Reservado a Super Embaixadores.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome é obrigatório.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_phone, '')), '') IS NULL THEN RAISE EXCEPTION 'Telefone é obrigatório.'; END IF;
    IF (NULLIF(TRIM(COALESCE(p_login_email, '')), '') IS NULL) <> (NULLIF(p_login_password, '') IS NULL) THEN
        RAISE EXCEPTION 'Para criar o acesso, indique email e senha.';
    END IF;

    v_id := 'amb-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_code := public.fn_amb_code(p_name);
    INSERT INTO public.ambassadors (id, name, phone, whatsapp, email, pix_mpesa, referral_code, is_super, parent_ambassador_id,
                                    status, active, language, currency, effective_from,
                                    geo_country, geo_province, geo_district, geo_city, geo_neighborhood)
    VALUES (v_id, TRIM(p_name), TRIM(p_phone), NULLIF(TRIM(COALESCE(p_whatsapp, '')), ''), NULLIF(TRIM(COALESCE(p_email, '')), ''),
            COALESCE(NULLIF(TRIM(COALESCE(p_pix_mpesa, '')), ''), 'M-Pesa ' || TRIM(p_phone)), v_code, FALSE, me.id,
            'ATIVO', TRUE, COALESCE(me.language, 'pt'), COALESCE(me.currency, 'MT'), CURRENT_DATE,
            me.geo_country, me.geo_province, me.geo_district, me.geo_city, me.geo_neighborhood);
    IF NULLIF(TRIM(COALESCE(p_login_email, '')), '') IS NOT NULL THEN
        v_uid := public.fn_internal_create_store_user(p_login_email, p_login_password, TRIM(p_name), 'EMBAIXADOR', NULL);
        UPDATE public.ambassadors SET user_id = v_uid WHERE id = v_id;
    END IF;
    PERFORM public.fn_amb_audit('CREATED_BY_SUPER', v_id, NULL, NULL, jsonb_build_object('super_id', me.id, 'login_created', v_uid IS NOT NULL));
    RETURN jsonb_build_object('success', TRUE, 'ambassador_id', v_id, 'referral_code', v_code);
END; $$;
REVOKE ALL ON FUNCTION public.fn_super_create_ambassador(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_super_create_ambassador(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;
-- Cadastro de lojas directas pelo Super Embaixador: reutiliza fn_ambassador_create_store (v2), que já aceita qualquer embaixador activo.

-- ------------------------------------------------------------------------------
-- 8. CONTEXTO DO UTILIZADOR (idioma/moeda, perfil efectivo, bloqueio, contacto do Super Embaixador)
--    Embaixador bloqueado recebe APENAS a mensagem e o motivo — nenhum dado operacional.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ambassador_context()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE me public.ambassadors%ROWTYPE; par public.ambassadors%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;
    SELECT * INTO me FROM public.ambassadors WHERE user_id = auth.uid() ORDER BY created_at LIMIT 1;
    IF me.id IS NULL THEN RETURN jsonb_build_object('ok', FALSE, 'code', 'AMBASSADOR_NOT_LINKED'); END IF;

    IF COALESCE(me.status, 'ATIVO') <> 'ATIVO' OR me.deleted_at IS NOT NULL THEN
        RETURN jsonb_build_object('ok', TRUE, 'blocked', TRUE, 'message', 'A sua conta está bloqueada.', 'reason', me.block_reason);
    END IF;

    IF me.parent_ambassador_id IS NOT NULL THEN
        SELECT * INTO par FROM public.ambassadors WHERE id = me.parent_ambassador_id AND deleted_at IS NULL;
    END IF;

    RETURN jsonb_build_object('ok', TRUE, 'blocked', FALSE,
        'ambassador_id', me.id, 'name', me.name, 'is_super', COALESCE(me.is_super, FALSE),
        'profile', CASE WHEN COALESCE(me.is_super, FALSE) THEN 'SUPER_EMBAIXADOR' ELSE 'EMBAIXADOR' END,
        'language', me.language, 'currency', me.currency,
        'area', concat_ws(', ', me.geo_neighborhood, me.geo_city, me.geo_district, me.geo_province, me.geo_country),
        'super_contact', CASE WHEN par.id IS NULL THEN NULL
                              ELSE jsonb_build_object('name', par.name, 'phone', par.phone, 'whatsapp', par.whatsapp) END);
END; $$;
REVOKE ALL ON FUNCTION public.fn_ambassador_context() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_context() TO authenticated;

-- Lista para o SUPERADMIN (inclui os novos campos; eliminados ficam de fora salvo pedido)
CREATE OR REPLACE FUNCTION public.fn_admin_list_ambassadors(p_include_deleted BOOLEAN DEFAULT FALSE)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    PERFORM public.fn_apply_due_rate_changes();
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', a.id, 'name', a.name, 'phone', a.phone, 'whatsapp', a.whatsapp, 'email', a.email,
        'status', COALESCE(a.status, CASE WHEN a.active THEN 'ATIVO' ELSE 'DESATIVADO' END),
        'block_reason', a.block_reason, 'is_super', COALESCE(a.is_super, FALSE), 'parent_ambassador_id', a.parent_ambassador_id,
        'commission_rate', COALESCE(a.commission_rate, 0), 'indirect_commission_rate', COALESCE(a.indirect_commission_rate, 0),
        'language', a.language, 'currency', a.currency, 'has_login', a.user_id IS NOT NULL, 'deleted', a.deleted_at IS NOT NULL,
        'geo_country', a.geo_country, 'geo_province', a.geo_province, 'geo_district', a.geo_district, 'geo_city', a.geo_city,
        'geo_neighborhood', a.geo_neighborhood, 'geo_description', a.geo_description, 'referral_code', a.referral_code,
        'stores', (SELECT COUNT(*) FROM public.ambassador_referred_stores r WHERE r.ambassador_id = a.id),
        'pending_rates', (SELECT COUNT(*) FROM public.ambassador_rate_schedule s WHERE s.ambassador_id = a.id AND s.applied_at IS NULL)
    ) ORDER BY a.created_at) FROM public.ambassadors a WHERE p_include_deleted OR a.deleted_at IS NULL), '[]'::JSONB);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_list_ambassadors(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_list_ambassadors(BOOLEAN) TO authenticated;

-- Auditoria para o SUPERADMIN
CREATE OR REPLACE FUNCTION public.fn_admin_ambassador_audit(p_ambassador_id TEXT DEFAULT NULL, p_limit INT DEFAULT 200)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (
        SELECT l.id, l.action, l.ambassador_id, l.store_ref_id, l.actor_id, l.actor_role, l.reason, l.details, l.created_at
          FROM public.ambassador_audit_log l
         WHERE p_ambassador_id IS NULL OR l.ambassador_id = p_ambassador_id
         ORDER BY l.created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000)) x), '[]'::JSONB);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_ambassador_audit(TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_ambassador_audit(TEXT, INT) TO authenticated;

-- ------------------------------------------------------------------------------
-- Diagnóstico (opcional): perfis, vínculos órfãos e lojas sem responsável activo.
-- SELECT is_super, COUNT(*) FROM public.ambassadors WHERE deleted_at IS NULL GROUP BY 1;
-- SELECT id, name FROM public.ambassadors WHERE parent_ambassador_id IS NOT NULL AND parent_ambassador_id NOT IN (SELECT id FROM public.ambassadors WHERE is_super);
-- ------------------------------------------------------------------------------

-- ------------------------------------------------------------------------------
-- 9. Funções existentes reescritas com UMA linha/bloco novo (copiadas da v4/v6, sem outras alterações)
--    9a. fn_ambassador_portal: devolve BLOCKED sem dados. 9b. fn_record_ambassador_commission: aplica taxas agendadas.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_ambassador_portal(p_ambassador_id TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid        UUID := auth.uid();
    v_role       TEXT;
    v_amb        public.ambassadors%ROWTYPE;
    v_amb_json   JSONB;
    v_stores     JSONB := '[]'::JSONB;
    v_payments   JSONB := '[]'::JSONB;
    v_payouts    JSONB := '[]'::JSONB;
    v_generated  NUMERIC := 0;
    v_paid       NUMERIC := 0;
    v_warnings   JSONB := '[]'::JSONB;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Sessão não autenticada.';
    END IF;

    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

    IF v_role = 'SUPERADMIN' AND p_ambassador_id IS NOT NULL THEN
        SELECT * INTO v_amb FROM public.ambassadors WHERE id = p_ambassador_id;
    ELSE
        -- Qualquer outro utilizador só pode ver o registo ligado ao seu próprio login.
        SELECT * INTO v_amb FROM public.ambassadors WHERE user_id = v_uid ORDER BY created_at LIMIT 1;
    END IF;

    IF v_amb.id IS NULL THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'AMBASSADOR_NOT_LINKED',
            'message', 'Não existe um cadastro de embaixador ligado a este login.'
        );
    END IF;

    -- v7: conta bloqueada/eliminada -> só mensagem e motivo, nenhum dado operacional.
    IF v_role IS DISTINCT FROM 'SUPERADMIN'
       AND (COALESCE(v_amb.status, 'ATIVO') <> 'ATIVO' OR v_amb.deleted_at IS NOT NULL) THEN
        RETURN JSONB_BUILD_OBJECT('ok', FALSE, 'code', 'BLOCKED',
                                  'message', 'A sua conta está bloqueada.', 'reason', v_amb.block_reason);
    END IF;

    v_amb_json := JSONB_BUILD_OBJECT(
        'id', v_amb.id,
        'user_id', v_amb.user_id,
        'name', v_amb.name,
        'phone', v_amb.phone,
        'pix_mpesa', v_amb.pix_mpesa,
        'referral_code', v_amb.referral_code,
        'commission_rate', COALESCE(v_amb.commission_rate, 0),
        'status', COALESCE(TO_JSONB(v_amb)->>'status',
                           CASE WHEN v_amb.active = FALSE THEN 'DESATIVADO' ELSE 'ATIVO' END),
        'pending_commissions', COALESCE(v_amb.pending_commissions, 0),
        'total_earned', COALESCE(v_amb.total_earned, 0),
        'created_at', v_amb.created_at
    );

    -- ---------------- LOJAS VINCULADAS (subscrição + comissão por loja) ----------------
    BEGIN
        SELECT COALESCE(JSONB_AGG(t.x ORDER BY t.created DESC NULLS LAST), '[]'::JSONB)
          INTO v_stores
          FROM (
            SELECT r.created_at AS created,
                   JSONB_BUILD_OBJECT(
                       'id', r.id,
                       'name', r.name,
                       'owner_name', r.owner_name,
                       'phone', r.phone,
                       'city', r.city,
                       'address', s.address,
                       'province', s.province,
                       'admin_email', (SELECT pf.email FROM public.profiles pf
                                        WHERE pf.store_id = s.id AND pf.role = 'ADMIN'
                                        ORDER BY pf.created_at, pf.email LIMIT 1),
                       'admin_name', (SELECT pf.full_name FROM public.profiles pf
                                        WHERE pf.store_id = s.id AND pf.role = 'ADMIN'
                                        ORDER BY pf.created_at, pf.email LIMIT 1),
                       'created_at', r.created_at,
                       'monthly_fee', COALESCE(s.valor_mensalidade, r.monthly_fee, 0),
                       'commission_rate', COALESCE(r.commission_rate, v_amb.commission_rate, 0),
                       'contract_duration_months', COALESCE(r.contract_duration_months, 12),
                       'months_active', COALESCE(r.months_active, 0),
                       'has_store', (s.id IS NOT NULL),
                       'subscription_status', CASE
                            WHEN s.id IS NULL THEN 'SEM_LOJA'
                            WHEN s.acesso_ativo = FALSE THEN 'BLOQUEADA'
                            WHEN s.data_fim_teste < CURRENT_DATE THEN 'EXPIRADA'
                            WHEN r.last_payment_date IS NULL THEN 'EM_TESTE'
                            ELSE 'ATIVA' END,
                       'subscription_end', s.data_fim_teste,
                       'days_remaining', CASE WHEN s.id IS NULL THEN NULL
                                              ELSE (s.data_fim_teste - CURRENT_DATE) END,
                       'last_payment_date', r.last_payment_date,
                       'payments_count', (SELECT COUNT(*) FROM public.ambassador_commission_payments p
                                           WHERE p.referred_store_id = r.id),
                       'total_paid_by_store', (SELECT COALESCE(SUM(p.payment_amount), 0)
                                                 FROM public.ambassador_commission_payments p
                                                WHERE p.referred_store_id = r.id),
                       'total_commission', (SELECT COALESCE(SUM(p.commission_amount), 0)
                                              FROM public.ambassador_commission_payments p
                                             WHERE p.referred_store_id = r.id)
                   ) AS x
              FROM public.ambassador_referred_stores r
              LEFT JOIN LATERAL (
                    SELECT q.* FROM (
                        SELECT s1.*, 1 AS prio
                          FROM public.stores s1
                         WHERE s1.id = COALESCE(r.store_id, r.id)
                        UNION ALL
                        SELECT s2.*, 2 AS prio
                          FROM public.stores s2
                         WHERE r.store_id IS NULL
                           AND NOT EXISTS (SELECT 1 FROM public.stores x1 WHERE x1.id = r.id)
                           AND REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g') <> ''
                           AND LOWER(TRIM(s2.name)) = LOWER(TRIM(r.name))
                           AND REGEXP_REPLACE(COALESCE(s2.phone, ''), '\D', '', 'g')
                             = REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g')
                           AND NOT EXISTS (SELECT 1 FROM public.ambassador_referred_stores z
                                            WHERE z.store_id = s2.id)
                           AND (SELECT COUNT(*) FROM public.stores y
                                 WHERE LOWER(TRIM(y.name)) = LOWER(TRIM(r.name))
                                   AND REGEXP_REPLACE(COALESCE(y.phone, ''), '\D', '', 'g')
                                     = REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g')) = 1
                    ) q
                    ORDER BY q.prio
                    LIMIT 1
              ) s ON TRUE
             WHERE r.ambassador_id = v_amb.id
          ) t;
    EXCEPTION WHEN OTHERS THEN
        v_warnings := v_warnings || TO_JSONB('lojas: ' || SQLERRM);
    END;

    -- ---------------- COMISSÃO GERADA EM CADA PAGAMENTO ----------------
    BEGIN
        SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
                   'id', p.id,
                   'referred_store_id', p.referred_store_id,
                   'store_name', p.store_name,
                   'paid_at', p.paid_at,
                   'payment_amount', p.payment_amount,
                   'commission_rate', p.commission_rate,
                   'commission_amount', p.commission_amount,
                   'days_added', p.days_added
               ) ORDER BY p.paid_at DESC), '[]'::JSONB),
               COALESCE(SUM(p.commission_amount), 0)
          INTO v_payments, v_generated
          FROM public.ambassador_commission_payments p
         WHERE p.ambassador_id = v_amb.id;
    EXCEPTION WHEN OTHERS THEN
        v_warnings := v_warnings || TO_JSONB('pagamentos: ' || SQLERRM);
    END;

    -- ---------------- HISTÓRICO DE LIQUIDAÇÕES (comissão recebida) ----------------
    BEGIN
        SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
                   'id', po.id,
                   'amount', po.amount,
                   'method', po.method,
                   'receipt', po.receipt,
                   'status', po.status,
                   'created_at', po.created_at
               ) ORDER BY po.created_at DESC), '[]'::JSONB),
               COALESCE(SUM(po.amount), 0)
          INTO v_payouts, v_paid
          FROM public.ambassador_payouts po
         WHERE po.ambassador_id = v_amb.id;
    EXCEPTION WHEN OTHERS THEN
        v_warnings := v_warnings || TO_JSONB('liquidacoes: ' || SQLERRM);
    END;

    RETURN JSONB_BUILD_OBJECT(
        'ok', TRUE,
        'generated_at', NOW(),
        'ambassador', v_amb_json,
        'stores', v_stores,
        'payments', v_payments,
        'payouts', v_payouts,
        'total_commission_generated', v_generated,
        'available_commission', COALESCE(v_amb.pending_commissions, 0),
        'paid_commission', v_paid,
        'warnings', v_warnings
    );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_ambassador_portal(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_portal(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_record_ambassador_commission(p_store_id TEXT, p_days INT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ref public.ambassador_referred_stores%ROWTYPE;
    v_store public.stores%ROWTYPE;
    v_parent public.ambassadors%ROWTYPE;
    v_payment NUMERIC(12, 2);
    v_commission NUMERIC(12, 2);
    v_ind NUMERIC(12, 2);
    v_months INT;
BEGIN
    PERFORM public.fn_apply_due_rate_changes(); -- v7: taxas agendadas cuja vigência já chegou
    SELECT * INTO v_ref
      FROM public.ambassador_referred_stores
     WHERE store_id = p_store_id OR id = p_store_id
     ORDER BY created_at
     LIMIT 1;
    IF v_ref.id IS NULL THEN RETURN; END IF;

    SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
    IF v_store.id IS NULL THEN RETURN; END IF;

    IF COALESCE(v_ref.contract_duration_months, 12) < 999
       AND COALESCE(v_ref.months_active, 0) >= COALESCE(v_ref.contract_duration_months, 12) THEN
        RETURN;
    END IF;

    v_payment := ROUND(COALESCE(v_store.valor_mensalidade, 0) * GREATEST(COALESCE(p_days, 30), 1) / 30.0, 2);
    IF v_payment <= 0 THEN RETURN; END IF;

    v_commission := ROUND(v_payment * COALESCE(v_ref.commission_rate, 0) / 100.0, 2);
    v_months := GREATEST(1, ROUND(COALESCE(p_days, 30) / 30.0)::INT);

    INSERT INTO public.ambassador_commission_payments (
        id, ambassador_id, referred_store_id, store_id, store_name,
        payment_amount, commission_rate, commission_amount, days_added, kind
    ) VALUES (
        'acp-' || REPLACE(gen_random_uuid()::TEXT, '-', ''),
        v_ref.ambassador_id, v_ref.id, p_store_id, v_store.name,
        v_payment, COALESCE(v_ref.commission_rate, 0), v_commission, COALESCE(p_days, 30), 'DIRECT'
    );

    UPDATE public.ambassador_referred_stores
       SET payment_status = 'PAGO',
           last_payment_date = CURRENT_DATE,
           next_due_date = v_store.data_fim_teste,
           months_active = COALESCE(months_active, 0) + v_months,
           total_commission_earned = COALESCE(total_commission_earned, 0) + v_commission
     WHERE id = v_ref.id;

    UPDATE public.ambassadors
       SET pending_commissions = COALESCE(pending_commissions, 0) + v_commission,
           total_earned = COALESCE(total_earned, 0) + v_commission
     WHERE id = v_ref.ambassador_id;

    -- Comissão INDIRECTA: só se o embaixador tem um Super Embaixador activo com taxa > 0.
    SELECT p.* INTO v_parent
      FROM public.ambassadors p
      JOIN public.ambassadors a ON a.parent_ambassador_id = p.id
     WHERE a.id = v_ref.ambassador_id;

    IF v_parent.id IS NOT NULL
       AND COALESCE(v_parent.is_super, FALSE)
       AND COALESCE(v_parent.indirect_commission_rate, 0) > 0
       AND COALESCE(v_parent.status, 'ATIVO') = 'ATIVO' THEN
        v_ind := ROUND(v_payment * v_parent.indirect_commission_rate / 100.0, 2);
        IF v_ind > 0 THEN
            INSERT INTO public.ambassador_commission_payments (
                id, ambassador_id, referred_store_id, store_id, store_name,
                payment_amount, commission_rate, commission_amount, days_added, kind, source_ambassador_id
            ) VALUES (
                'acp-' || REPLACE(gen_random_uuid()::TEXT, '-', ''),
                v_parent.id, NULL, p_store_id, v_store.name,
                v_payment, v_parent.indirect_commission_rate, v_ind, COALESCE(p_days, 30), 'INDIRECT', v_ref.ambassador_id
            );
            UPDATE public.ambassadors
               SET pending_commissions = COALESCE(pending_commissions, 0) + v_ind,
                   total_earned = COALESCE(total_earned, 0) + v_ind
             WHERE id = v_parent.id;
        END IF;
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_record_ambassador_commission(TEXT, INT) FROM PUBLIC, anon, authenticated;
