-- ==============================================================================
-- GEF | MIGRAÇÃO EMBAIXADORES v2
-- Executar UMA vez no Supabase (SQL Editor). É idempotente: pode ser repetida.
--
-- O que faz (e só isto):
--  1. Super Admin: editar embaixador, bloquear/desbloquear, comissão padrão e por loja.
--  2. Link do embaixador consistente: o código (referral_code) passa a ser imutável.
--  3. Embaixador: cria loja + utilizadores da loja (sem poder editar depois e sem
--     ver dados internos da loja).
--  4. Embaixador: acompanha as lojas (subscrição, dias, comissão por pagamento e total).
--
-- NÃO altera vendas, stock, caixa, PDV nem qualquer outro módulo.
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ------------------------------------------------------------------------------
-- 1. COLUNAS / TABELAS NOVAS (apenas adições)
-- ------------------------------------------------------------------------------

-- Estado do embaixador: ATIVO | BLOQUEADO | DESATIVADO
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS status TEXT;
UPDATE public.ambassadors
   SET status = CASE WHEN active = FALSE THEN 'DESATIVADO' ELSE 'ATIVO' END
 WHERE status IS NULL;
ALTER TABLE public.ambassadors ALTER COLUMN status SET DEFAULT 'ATIVO';

-- Ligação da loja indicada à loja real (para acompanhar a subscrição)
ALTER TABLE public.ambassador_referred_stores ADD COLUMN IF NOT EXISTS store_id TEXT;
UPDATE public.ambassador_referred_stores r
   SET store_id = r.id
 WHERE r.store_id IS NULL
   AND EXISTS (SELECT 1 FROM public.stores s WHERE s.id = r.id);

-- Comissão recebida em cada pagamento de subscrição
CREATE TABLE IF NOT EXISTS public.ambassador_commission_payments (
    id TEXT PRIMARY KEY,
    ambassador_id TEXT NOT NULL REFERENCES public.ambassadors(id) ON DELETE CASCADE,
    referred_store_id TEXT,
    store_id TEXT,
    store_name TEXT,
    payment_amount NUMERIC(12, 2) NOT NULL DEFAULT 0,
    commission_rate NUMERIC(5, 2) NOT NULL DEFAULT 0,
    commission_amount NUMERIC(12, 2) NOT NULL DEFAULT 0,
    days_added INT DEFAULT 30,
    paid_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_amb_comm_pay_amb ON public.ambassador_commission_payments(ambassador_id);
ALTER TABLE public.ambassador_commission_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "amb_comm_payments_select" ON public.ambassador_commission_payments;
CREATE POLICY "amb_comm_payments_select" ON public.ambassador_commission_payments FOR SELECT TO authenticated
USING (
    public.get_auth_user_role() = 'SUPERADMIN'
    OR EXISTS (SELECT 1 FROM public.ambassadors a
                WHERE a.id = ambassador_commission_payments.ambassador_id
                  AND a.user_id = auth.uid())
);
-- Sem policies de INSERT/UPDATE/DELETE: só as funções SECURITY DEFINER escrevem aqui.

-- ------------------------------------------------------------------------------
-- 2. EMBAIXADOR SÓ LÊ AS SUAS LOJAS INDICADAS (não pode editar nem apagar)
--    Antes a policy era FOR ALL (o embaixador podia apagar as próprias linhas).
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "ambassador_referred_stores_via_ambassador" ON public.ambassador_referred_stores;
DROP POLICY IF EXISTS "ambassador_referred_stores_superadmin_all" ON public.ambassador_referred_stores;
DROP POLICY IF EXISTS "ambassador_referred_stores_owner_select" ON public.ambassador_referred_stores;

CREATE POLICY "ambassador_referred_stores_superadmin_all" ON public.ambassador_referred_stores FOR ALL TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "ambassador_referred_stores_owner_select" ON public.ambassador_referred_stores FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.ambassadors a
                WHERE a.id = ambassador_referred_stores.ambassador_id
                  AND a.user_id = auth.uid()));

-- ------------------------------------------------------------------------------
-- 3. LINK CONSISTENTE: o código de indicação nunca muda depois de criado
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_lock_ambassador_referral_code()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.referral_code IS NOT NULL THEN
        NEW.referral_code := OLD.referral_code;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_lock_ambassador_referral_code ON public.ambassadors;
CREATE TRIGGER trg_lock_ambassador_referral_code
    BEFORE UPDATE ON public.ambassadors
    FOR EACH ROW EXECUTE FUNCTION public.fn_lock_ambassador_referral_code();

-- ------------------------------------------------------------------------------
-- 4. SUPER ADMIN: EDITAR / BLOQUEAR / COMISSÕES
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_admin_update_ambassador(TEXT, TEXT, TEXT, TEXT, NUMERIC);
CREATE OR REPLACE FUNCTION public.fn_admin_update_ambassador(
    p_ambassador_id TEXT,
    p_name TEXT,
    p_phone TEXT,
    p_pix_mpesa TEXT,
    p_commission_rate NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_code TEXT;
BEGIN
    IF public.get_auth_user_role() IS DISTINCT FROM 'SUPERADMIN' THEN
        RAISE EXCEPTION 'Apenas o Super Admin pode editar embaixadores.';
    END IF;
    IF NULLIF(TRIM(p_name), '') IS NULL THEN RAISE EXCEPTION 'Nome do embaixador é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_phone), '') IS NULL THEN RAISE EXCEPTION 'Telefone do embaixador é obrigatório.'; END IF;
    IF p_commission_rate IS NULL OR p_commission_rate < 0 OR p_commission_rate > 100 THEN
        RAISE EXCEPTION 'Taxa de comissão inválida (0 a 100).';
    END IF;

    UPDATE public.ambassadors
       SET name = TRIM(p_name),
           phone = TRIM(p_phone),
           pix_mpesa = COALESCE(NULLIF(TRIM(p_pix_mpesa), ''), pix_mpesa),
           commission_rate = p_commission_rate
     WHERE id = p_ambassador_id;

    -- Compatibilidade: o modal "Novo Embaixador" envia um id novo -> cria o registo.
    IF NOT FOUND THEN
        v_code := 'GEF-' || UPPER(REGEXP_REPLACE(SPLIT_PART(TRIM(p_name), ' ', 1), '[^A-Za-z0-9]', '', 'g'))
                  || '-' || EXTRACT(YEAR FROM NOW())::INT;
        IF EXISTS (SELECT 1 FROM public.ambassadors WHERE referral_code = v_code) THEN
            v_code := v_code || '-' || UPPER(SUBSTR(MD5(RANDOM()::TEXT), 1, 4));
        END IF;
        INSERT INTO public.ambassadors (id, name, phone, pix_mpesa, referral_code, commission_rate, status, active)
        VALUES (p_ambassador_id, TRIM(p_name), TRIM(p_phone),
                COALESCE(NULLIF(TRIM(p_pix_mpesa), ''), 'M-Pesa ' || TRIM(p_phone)),
                v_code, p_commission_rate, 'ATIVO', TRUE);
    END IF;

    SELECT referral_code INTO v_code FROM public.ambassadors WHERE id = p_ambassador_id;

    RETURN jsonb_build_object('success', TRUE, 'ambassador_id', p_ambassador_id, 'referral_code', v_code);
END;
$$;

DROP FUNCTION IF EXISTS public.fn_admin_set_ambassador_status(TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.fn_admin_set_ambassador_status(
    p_ambassador_id TEXT,
    p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_status TEXT := UPPER(TRIM(COALESCE(p_status, '')));
    v_user UUID;
BEGIN
    IF public.get_auth_user_role() IS DISTINCT FROM 'SUPERADMIN' THEN
        RAISE EXCEPTION 'Apenas o Super Admin pode alterar o estado de embaixadores.';
    END IF;
    IF v_status NOT IN ('ATIVO', 'BLOQUEADO', 'DESATIVADO') THEN
        RAISE EXCEPTION 'Estado inválido: %', p_status;
    END IF;

    UPDATE public.ambassadors
       SET status = v_status,
           active = (v_status = 'ATIVO')
     WHERE id = p_ambassador_id
    RETURNING user_id INTO v_user;

    IF NOT FOUND THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;

    -- Bloqueado/desativado deixa de entrar no sistema; desbloquear volta a permitir.
    IF v_user IS NOT NULL THEN
        UPDATE public.profiles
           SET active = (v_status = 'ATIVO'), updated_at = NOW()
         WHERE id = v_user AND role = 'EMBAIXADOR';
    END IF;

    RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END;
$$;

-- Comissão específica de UMA loja indicada (não altera as outras)
DROP FUNCTION IF EXISTS public.fn_admin_set_referred_store_commission(TEXT, NUMERIC);
CREATE OR REPLACE FUNCTION public.fn_admin_set_referred_store_commission(
    p_referred_store_id TEXT,
    p_commission_rate NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF public.get_auth_user_role() IS DISTINCT FROM 'SUPERADMIN' THEN
        RAISE EXCEPTION 'Apenas o Super Admin pode alterar a comissão de uma loja.';
    END IF;
    IF p_commission_rate IS NULL OR p_commission_rate < 0 OR p_commission_rate > 100 THEN
        RAISE EXCEPTION 'Taxa de comissão inválida (0 a 100).';
    END IF;

    UPDATE public.ambassador_referred_stores
       SET commission_rate = p_commission_rate
     WHERE id = p_referred_store_id;

    IF NOT FOUND THEN RAISE EXCEPTION 'Loja indicada não encontrada.'; END IF;
    RETURN jsonb_build_object('success', TRUE, 'commission_rate', p_commission_rate);
END;
$$;

-- ------------------------------------------------------------------------------
-- 5. EMBAIXADOR: CRIAR LOJA + UTILIZADORES (sem editar depois)
-- ------------------------------------------------------------------------------

-- Cria um utilizador de autenticação + perfil. Uso interno (não exposta ao cliente).
CREATE OR REPLACE FUNCTION public.fn_internal_create_store_user(
    p_email TEXT,
    p_password TEXT,
    p_full_name TEXT,
    p_role TEXT,
    p_store_id TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, auth, pg_temp
AS $$
DECLARE
    v_uid UUID := gen_random_uuid();
    v_email TEXT := LOWER(TRIM(p_email));
BEGIN
    IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
        RAISE EXCEPTION 'Email inválido: %', p_email;
    END IF;
    IF p_password IS NULL OR LENGTH(p_password) < 8 THEN
        RAISE EXCEPTION 'A palavra-passe deve ter pelo menos 8 caracteres.';
    END IF;
    IF p_role NOT IN ('ADMIN', 'GERENTE', 'CASHIER', 'ESTOQUISTA', 'EMBAIXADOR') THEN
        RAISE EXCEPTION 'Função inválida para utilizador de loja: %', p_role;
    END IF;
    IF EXISTS (SELECT 1 FROM auth.users WHERE LOWER(email) = v_email) THEN
        RAISE EXCEPTION 'Já existe um utilizador com o email %.', v_email;
    END IF;

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, email_change, email_change_token_new, recovery_token
    ) VALUES (
        '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
        v_email, crypt(p_password, gen_salt('bf')), NOW(),
        '{"provider":"email","providers":["email"]}'::JSONB,
        jsonb_build_object('full_name', TRIM(p_full_name)),
        NOW(), NOW(), '', '', '', ''
    );

    INSERT INTO auth.identities (
        id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) VALUES (
        gen_random_uuid(), v_uid, v_uid::TEXT,
        jsonb_build_object('sub', v_uid::TEXT, 'email', v_email, 'email_verified', TRUE),
        'email', NOW(), NOW(), NOW()
    );

    -- O trigger handle_new_user já criou o perfil (CASHIER, inativo, sem loja): ajusta.
    UPDATE public.profiles
       SET email = v_email,
           full_name = TRIM(p_full_name),
           role = p_role,
           store_id = p_store_id,
           active = TRUE,
           updated_at = NOW()
     WHERE id = v_uid;

    IF NOT FOUND THEN
        INSERT INTO public.profiles (id, email, full_name, role, store_id, active)
        VALUES (v_uid, v_email, TRIM(p_full_name), p_role, p_store_id, TRUE);
    END IF;

    RETURN v_uid;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_internal_create_store_user(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- Valida que o chamador é o embaixador (ativo) ou o Super Admin
CREATE OR REPLACE FUNCTION public.fn_ambassador_resolve(p_ambassador_id TEXT, p_require_active BOOLEAN DEFAULT TRUE)
RETURNS public.ambassadors
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
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
    IF p_require_active AND COALESCE(v_amb.status, 'ATIVO') <> 'ATIVO' THEN
        RAISE EXCEPTION 'A sua conta de embaixador está bloqueada. Contacte o administrador.';
    END IF;
    RETURN v_amb;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_ambassador_resolve(TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_resolve(TEXT, BOOLEAN) TO authenticated;

DROP FUNCTION IF EXISTS public.fn_ambassador_create_store(TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, INT, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.fn_ambassador_create_store(
    p_ambassador_id TEXT,
    p_store_name TEXT,
    p_owner_name TEXT,
    p_phone TEXT,
    p_city TEXT,
    p_monthly_fee NUMERIC,
    p_contract_months INT,
    p_admin_email TEXT,
    p_admin_password TEXT,
    p_address TEXT DEFAULT NULL,
    p_nuit_nif TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, auth, pg_temp
AS $$
DECLARE
    v_amb public.ambassadors%ROWTYPE;
    v_store_id TEXT;
    v_store_code TEXT;
    v_uid UUID;
BEGIN
    v_amb := public.fn_ambassador_resolve(p_ambassador_id, TRUE);

    IF NULLIF(TRIM(p_store_name), '') IS NULL THEN RAISE EXCEPTION 'Nome da loja é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_owner_name), '') IS NULL THEN RAISE EXCEPTION 'Nome do responsável é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_phone), '') IS NULL THEN RAISE EXCEPTION 'Telefone é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_city), '') IS NULL THEN RAISE EXCEPTION 'Cidade é obrigatória.'; END IF;
    IF COALESCE(p_monthly_fee, 0) < 0 THEN RAISE EXCEPTION 'Mensalidade inválida.'; END IF;

    v_store_id := 'store-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_store_code := 'REF-' || UPPER(SUBSTR(MD5(RANDOM()::TEXT || CLOCK_TIMESTAMP()::TEXT), 1, 8));

    INSERT INTO public.stores (
        id, code, name, trade_name, nuit_nif, city, address, phone,
        currency, language, is_headquarters,
        valor_mensalidade, data_inicio_teste, data_fim_teste, acesso_ativo
    ) VALUES (
        v_store_id, v_store_code, TRIM(p_store_name), TRIM(p_store_name),
        NULLIF(TRIM(p_nuit_nif), ''), TRIM(p_city), NULLIF(TRIM(p_address), ''), TRIM(p_phone),
        'MT', 'pt', FALSE,
        COALESCE(p_monthly_fee, 0), NOW(), CURRENT_DATE + 30, TRUE
    );

    -- Administrador inicial da loja (definido pelo embaixador; a loja pode trocar a senha)
    v_uid := public.fn_internal_create_store_user(p_admin_email, p_admin_password, p_owner_name, 'ADMIN', v_store_id);

    INSERT INTO public.ambassador_referred_stores (
        id, store_id, ambassador_id, name, owner_name, phone, city,
        monthly_fee, payment_status, next_due_date,
        commission_rate, contract_duration_months, months_active, total_commission_earned
    ) VALUES (
        v_store_id, v_store_id, v_amb.id, TRIM(p_store_name), TRIM(p_owner_name), TRIM(p_phone), TRIM(p_city),
        COALESCE(p_monthly_fee, 0), 'PENDENTE', CURRENT_DATE + 30,
        COALESCE(v_amb.commission_rate, 15), COALESCE(NULLIF(p_contract_months, 0), 12), 0, 0
    );

    RETURN jsonb_build_object(
        'success', TRUE,
        'store_id', v_store_id,
        'store_code', v_store_code,
        'admin_user_id', v_uid,
        'admin_email', LOWER(TRIM(p_admin_email)),
        'commission_rate', COALESCE(v_amb.commission_rate, 15)
    );
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_create_store(TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, INT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

DROP FUNCTION IF EXISTS public.fn_ambassador_create_store_user(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.fn_ambassador_create_store_user(
    p_ambassador_id TEXT,
    p_referred_store_id TEXT,
    p_email TEXT,
    p_password TEXT,
    p_full_name TEXT,
    p_role TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, auth, pg_temp
AS $$
DECLARE
    v_amb public.ambassadors%ROWTYPE;
    v_store_id TEXT;
    v_uid UUID;
BEGIN
    v_amb := public.fn_ambassador_resolve(p_ambassador_id, TRUE);

    IF UPPER(TRIM(COALESCE(p_role, ''))) NOT IN ('ADMIN', 'CASHIER') THEN
        RAISE EXCEPTION 'O embaixador só pode criar utilizadores Admin ou Caixa.';
    END IF;

    SELECT COALESCE(r.store_id, r.id) INTO v_store_id
      FROM public.ambassador_referred_stores r
     WHERE r.id = p_referred_store_id AND r.ambassador_id = v_amb.id;

    IF v_store_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.stores WHERE id = v_store_id) THEN
        RAISE EXCEPTION 'Loja não encontrada ou não pertence a este embaixador.';
    END IF;

    v_uid := public.fn_internal_create_store_user(p_email, p_password, p_full_name, UPPER(TRIM(p_role)), v_store_id);
    RETURN jsonb_build_object('success', TRUE, 'user_id', v_uid, 'email', LOWER(TRIM(p_email)));
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_create_store_user(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 6. COMISSÃO POR PAGAMENTO (ligada à renovação da subscrição pelo Super Admin)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_record_ambassador_commission(p_store_id TEXT, p_days INT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_ref public.ambassador_referred_stores%ROWTYPE;
    v_store public.stores%ROWTYPE;
    v_payment NUMERIC(12, 2);
    v_commission NUMERIC(12, 2);
    v_months INT;
BEGIN
    SELECT * INTO v_ref
      FROM public.ambassador_referred_stores
     WHERE store_id = p_store_id OR id = p_store_id
     ORDER BY created_at
     LIMIT 1;
    IF v_ref.id IS NULL THEN RETURN; END IF;

    SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
    IF v_store.id IS NULL THEN RETURN; END IF;

    -- Vigência da comissão (999 = vitalício)
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
        payment_amount, commission_rate, commission_amount, days_added
    ) VALUES (
        'acp-' || REPLACE(gen_random_uuid()::TEXT, '-', ''),
        v_ref.ambassador_id, v_ref.id, p_store_id, v_store.name,
        v_payment, COALESCE(v_ref.commission_rate, 0), v_commission, COALESCE(p_days, 30)
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
END;
$$;
REVOKE ALL ON FUNCTION public.fn_record_ambassador_commission(TEXT, INT) FROM PUBLIC, anon, authenticated;

-- Mesma função de renovação que já existia; apenas acrescenta o registo da comissão.
-- Se o registo da comissão falhar, a renovação NÃO é afetada (só emite aviso).
CREATE OR REPLACE FUNCTION public.fn_renew_store_subscription(p_store_id TEXT, p_days INT DEFAULT 30)
RETURNS public.stores AS $$
DECLARE
    v_store public.stores;
BEGIN
    IF public.get_auth_user_role() <> 'SUPERADMIN' THEN
        RAISE EXCEPTION 'Apenas o Superadmin pode renovar assinaturas de lojas.';
    END IF;

    UPDATE public.stores
    SET data_fim_teste = GREATEST(data_fim_teste, CURRENT_DATE) + (p_days || ' days')::INTERVAL,
        acesso_ativo = TRUE,
        motivo_bloqueio = NULL
    WHERE id = p_store_id
    RETURNING * INTO v_store;

    IF NOT FOUND THEN RAISE EXCEPTION 'Loja não encontrada.'; END IF;

    BEGIN
        PERFORM public.fn_record_ambassador_commission(p_store_id, p_days);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Comissão de embaixador não registada para %: %', p_store_id, SQLERRM;
    END;

    RETURN v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ------------------------------------------------------------------------------
-- 7. PAINEL DE ACOMPANHAMENTO (só dados de subscrição/comissão; nada interno da loja)
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_ambassador_tracking(TEXT);
CREATE OR REPLACE FUNCTION public.fn_ambassador_tracking(p_ambassador_id TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_amb public.ambassadors%ROWTYPE;
    v_stores JSONB;
    v_payments JSONB;
BEGIN
    v_amb := public.fn_ambassador_resolve(p_ambassador_id, FALSE);

    SELECT COALESCE(JSONB_AGG(x ORDER BY x->>'created_at' DESC), '[]'::JSONB) INTO v_stores
    FROM (
        SELECT JSONB_BUILD_OBJECT(
            'id', r.id,
            'name', r.name,
            'owner_name', r.owner_name,
            'phone', r.phone,
            'city', r.city,
            'created_at', r.created_at,
            'monthly_fee', COALESCE(s.valor_mensalidade, r.monthly_fee, 0),
            'commission_rate', COALESCE(r.commission_rate, v_amb.commission_rate, 0),
            'contract_duration_months', r.contract_duration_months,
            'months_active', COALESCE(r.months_active, 0),
            'has_store', (s.id IS NOT NULL),
            'subscription_status', CASE
                WHEN s.id IS NULL THEN 'SEM_LOJA'
                WHEN s.acesso_ativo = FALSE THEN 'BLOQUEADA'
                WHEN s.data_fim_teste < CURRENT_DATE THEN 'EXPIRADA'
                WHEN r.last_payment_date IS NULL THEN 'EM_TESTE'
                ELSE 'ATIVA' END,
            'subscription_end', s.data_fim_teste,
            'days_remaining', CASE WHEN s.id IS NULL THEN NULL ELSE (s.data_fim_teste - CURRENT_DATE) END,
            'last_payment_date', r.last_payment_date,
            'payments_count', (SELECT COUNT(*) FROM public.ambassador_commission_payments p WHERE p.referred_store_id = r.id),
            'total_paid_by_store', (SELECT COALESCE(SUM(p.payment_amount), 0) FROM public.ambassador_commission_payments p WHERE p.referred_store_id = r.id),
            'total_commission', (SELECT COALESCE(SUM(p.commission_amount), 0) FROM public.ambassador_commission_payments p WHERE p.referred_store_id = r.id)
        ) AS x
        FROM public.ambassador_referred_stores r
        LEFT JOIN public.stores s ON s.id = COALESCE(r.store_id, r.id)
        WHERE r.ambassador_id = v_amb.id
    ) t;

    SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
        'id', p.id,
        'referred_store_id', p.referred_store_id,
        'store_name', p.store_name,
        'paid_at', p.paid_at,
        'payment_amount', p.payment_amount,
        'commission_rate', p.commission_rate,
        'commission_amount', p.commission_amount,
        'days_added', p.days_added
    ) ORDER BY p.paid_at DESC), '[]'::JSONB) INTO v_payments
    FROM public.ambassador_commission_payments p
    WHERE p.ambassador_id = v_amb.id;

    RETURN JSONB_BUILD_OBJECT(
        'ambassador_id', v_amb.id,
        'stores', v_stores,
        'payments', v_payments,
        'total_commission_generated', (SELECT COALESCE(SUM(commission_amount), 0) FROM public.ambassador_commission_payments WHERE ambassador_id = v_amb.id)
    );
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_tracking(TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 8. SUPER ADMIN: CRIAR ACESSO (LOGIN) DO EMBAIXADOR
--    Sem isto o embaixador não consegue entrar para ver o painel nem criar lojas.
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_admin_create_ambassador_login(TEXT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.fn_admin_create_ambassador_login(
    p_ambassador_id TEXT,
    p_email TEXT,
    p_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, auth, pg_temp
AS $$
DECLARE
    v_amb public.ambassadors%ROWTYPE;
    v_uid UUID;
BEGIN
    IF public.get_auth_user_role() IS DISTINCT FROM 'SUPERADMIN' THEN
        RAISE EXCEPTION 'Apenas o Super Admin pode criar o acesso de um embaixador.';
    END IF;

    SELECT * INTO v_amb FROM public.ambassadors WHERE id = p_ambassador_id;
    IF v_amb.id IS NULL THEN RAISE EXCEPTION 'Embaixador não encontrado.'; END IF;
    IF v_amb.user_id IS NOT NULL THEN RAISE EXCEPTION 'Este embaixador já tem acesso criado.'; END IF;

    v_uid := public.fn_internal_create_store_user(p_email, p_password, v_amb.name, 'EMBAIXADOR', NULL);

    UPDATE public.ambassadors SET user_id = v_uid WHERE id = v_amb.id;

    RETURN jsonb_build_object('success', TRUE, 'user_id', v_uid, 'email', LOWER(TRIM(p_email)));
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_admin_create_ambassador_login(TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 9. EMBAIXADOR NÃO PODE ALTERAR NEM APAGAR PAGAMENTOS (só ler os seus)
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "ambassador_payouts_via_ambassador" ON public.ambassador_payouts;
DROP POLICY IF EXISTS "ambassador_payouts_superadmin_all" ON public.ambassador_payouts;
DROP POLICY IF EXISTS "ambassador_payouts_owner_select" ON public.ambassador_payouts;

CREATE POLICY "ambassador_payouts_superadmin_all" ON public.ambassador_payouts FOR ALL TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "ambassador_payouts_owner_select" ON public.ambassador_payouts FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.ambassadors a
                WHERE a.id = ambassador_payouts.ambassador_id
                  AND a.user_id = auth.uid()));

-- ------------------------------------------------------------------------------
-- 10. ADESÃO PELO LINK: já não credita comissão no registo.
--     A loja entra como PENDENTE; a comissão nasce a cada pagamento lançado (secção 6).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_complete_ambassador_onboarding(
    p_referral_code TEXT,
    p_store_name TEXT,
    p_owner_name TEXT,
    p_phone TEXT,
    p_city TEXT,
    p_address TEXT DEFAULT NULL,
    p_nuit_nif TEXT DEFAULT NULL,
    p_monthly_fee NUMERIC DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID;
    v_user_email TEXT;

    v_ambassador public.ambassadors%ROWTYPE;

    v_store_id TEXT;
    v_store_code TEXT;

    v_commission_rate NUMERIC(5,2);
    v_commission NUMERIC(12,2);

    v_existing_store TEXT;
BEGIN
    -- --------------------------------------------------------
    -- Utilizador autenticado
    -- --------------------------------------------------------

    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'É necessário estar autenticado para concluir a adesão.';
    END IF;


    SELECT email
    INTO v_user_email
    FROM auth.users
    WHERE id = v_user_id;


    IF v_user_email IS NULL THEN
        RAISE EXCEPTION 'Utilizador Auth não encontrado.';
    END IF;


    -- --------------------------------------------------------
    -- Validar embaixador
    -- --------------------------------------------------------

    SELECT *
    INTO v_ambassador
    FROM public.ambassadors
    WHERE UPPER(TRIM(referral_code)) =
          UPPER(TRIM(p_referral_code))
      AND active = TRUE
    LIMIT 1;


    IF v_ambassador.id IS NULL THEN
        RAISE EXCEPTION 'Código de embaixador inválido ou inativo.';
    END IF;


    -- --------------------------------------------------------
    -- Validar dados básicos
    -- --------------------------------------------------------

    IF NULLIF(TRIM(p_store_name), '') IS NULL THEN
        RAISE EXCEPTION 'Nome da loja é obrigatório.';
    END IF;

    IF NULLIF(TRIM(p_owner_name), '') IS NULL THEN
        RAISE EXCEPTION 'Nome do responsável é obrigatório.';
    END IF;

    IF NULLIF(TRIM(p_phone), '') IS NULL THEN
        RAISE EXCEPTION 'Telefone é obrigatório.';
    END IF;

    IF NULLIF(TRIM(p_city), '') IS NULL THEN
        RAISE EXCEPTION 'Cidade é obrigatória.';
    END IF;


    -- --------------------------------------------------------
    -- O mesmo utilizador não pode ser reutilizado para outra
    -- loja através desta adesão.
    -- --------------------------------------------------------

    SELECT store_id
    INTO v_existing_store
    FROM public.profiles
    WHERE id = v_user_id
    LIMIT 1;

    IF v_existing_store IS NOT NULL THEN
        RAISE EXCEPTION 'Este utilizador já está associado a uma loja.';
    END IF;


    -- --------------------------------------------------------
    -- Gerar IDs
    -- --------------------------------------------------------

    v_store_id :=
        'store-ref-' ||
        replace(v_user_id::TEXT, '-', '');

    v_store_code :=
        'REF-' ||
        upper(substr(md5(random()::TEXT || clock_timestamp()::TEXT), 1, 8));


    -- --------------------------------------------------------
    -- Comissão
    -- --------------------------------------------------------

    v_commission_rate :=
        COALESCE(v_ambassador.commission_rate, 15);

    v_commission := 0; -- a comissão é registada a cada pagamento lançado pelo Super Admin


    -- --------------------------------------------------------
    -- Criar loja
    -- --------------------------------------------------------

    INSERT INTO public.stores (
        id,
        code,
        name,
        trade_name,
        nuit_nif,
        city,
        address,
        phone,
        currency,
        language,
        is_headquarters,
        valor_mensalidade,
        data_inicio_teste,
        data_fim_teste,
        acesso_ativo
    )
    VALUES (
        v_store_id,
        v_store_code,
        TRIM(p_store_name),
        TRIM(p_store_name),
        NULLIF(TRIM(p_nuit_nif), ''),
        TRIM(p_city),
        NULLIF(TRIM(p_address), ''),
        TRIM(p_phone),
        'MZN',
        'pt-MZ',
        FALSE,
        COALESCE(p_monthly_fee, 0),
        CURRENT_DATE,
        CURRENT_DATE + 30,
        TRUE
    );


    -- --------------------------------------------------------
    -- Transformar utilizador atual em ADMIN
    -- --------------------------------------------------------

    UPDATE public.profiles
    SET
        email = v_user_email,
        full_name = TRIM(p_owner_name),
        role = 'ADMIN',
        store_id = v_store_id,
        active = TRUE,
        updated_at = NOW()
    WHERE id = v_user_id;


    IF NOT FOUND THEN
        INSERT INTO public.profiles (
            id,
            email,
            full_name,
            role,
            store_id,
            active
        )
        VALUES (
            v_user_id,
            v_user_email,
            TRIM(p_owner_name),
            'ADMIN',
            v_store_id,
            TRUE
        );
    END IF;


    -- --------------------------------------------------------
    -- Registrar indicação do embaixador
    -- --------------------------------------------------------

    INSERT INTO public.ambassador_referred_stores (
        id,
        store_id,
        ambassador_id,
        name,
        owner_name,
        phone,
        city,
        monthly_fee,
        payment_status,
        commission_rate,
        contract_duration_months,
        total_commission_earned
    )
    VALUES (
        v_store_id,
        v_store_id,
        v_ambassador.id,
        TRIM(p_store_name),
        TRIM(p_owner_name),
        TRIM(p_phone),
        TRIM(p_city),
        COALESCE(p_monthly_fee, 0),
        'PENDENTE',
        v_commission_rate,
        12,
        v_commission
    );


    -- --------------------------------------------------------
    -- Atualizar comissão pendente do embaixador
    -- --------------------------------------------------------

    IF v_commission > 0 THEN

        UPDATE public.ambassadors
        SET pending_commissions =
            COALESCE(pending_commissions, 0)
            + v_commission
        WHERE id = v_ambassador.id;

    END IF;


    -- --------------------------------------------------------
    -- Resultado
    -- --------------------------------------------------------

    RETURN jsonb_build_object(
        'success', TRUE,
        'store_id', v_store_id,
        'store_code', v_store_code,
        'ambassador_id', v_ambassador.id,
        'ambassador_name', v_ambassador.name,
        'commission_rate', v_commission_rate,
        'commission', v_commission,
        'admin_user_id', v_user_id,
        'admin_email', v_user_email
    );

EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Não foi possível concluir a adesão porque alguns dados já existem.';
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_complete_ambassador_onboarding(
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    NUMERIC
)
TO authenticated;

-- ==============================================================================
-- 11. LINK DO EMBAIXADOR (página pública adesao.html) — funções que faltavam
-- ==============================================================================

-- 11a. Validação do código: devolve JSON simples (antes devolvia TABLE -> o JS recebia um array)
DROP FUNCTION IF EXISTS public.fn_validate_ambassador_code(TEXT);
CREATE OR REPLACE FUNCTION public.fn_validate_ambassador_code(p_referral_code TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        (SELECT jsonb_build_object(
                    'valid', TRUE,
                    'id', a.id,
                    'name', a.name,
                    'referral_code', a.referral_code,
                    'status', COALESCE(a.status, CASE WHEN a.active THEN 'ATIVO' ELSE 'DESATIVADO' END)
                )
           FROM public.ambassadors a
          WHERE UPPER(TRIM(a.referral_code)) = UPPER(TRIM(p_referral_code))
            AND COALESCE(a.status, CASE WHEN a.active THEN 'ATIVO' ELSE 'DESATIVADO' END) = 'ATIVO'
          LIMIT 1),
        jsonb_build_object('valid', FALSE, 'message', 'Link de embaixador inválido ou inativo.')
    );
$$;
GRANT EXECUTE ON FUNCTION public.fn_validate_ambassador_code(TEXT) TO anon, authenticated;

-- 11b. Painel público do link: SÓ nome/código/estado. Nunca ganhos, telefones nem lojas de terceiros.
DROP FUNCTION IF EXISTS public.fn_get_public_ambassador_dashboard(TEXT);
CREATE OR REPLACE FUNCTION public.fn_get_public_ambassador_dashboard(p_referral_code TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT COALESCE(
        (SELECT jsonb_build_object(
                    'valid', TRUE,
                    'ambassador', jsonb_build_object(
                        'name', a.name,
                        'referral_code', a.referral_code,
                        'status', COALESCE(a.status, CASE WHEN a.active THEN 'ATIVO' ELSE 'DESATIVADO' END)
                    ),
                    'stores', '[]'::JSONB
                )
           FROM public.ambassadors a
          WHERE UPPER(TRIM(a.referral_code)) = UPPER(TRIM(p_referral_code))
          LIMIT 1),
        jsonb_build_object('valid', FALSE, 'message', 'Este link de embaixador não é válido.')
    );
$$;
GRANT EXECUTE ON FUNCTION public.fn_get_public_ambassador_dashboard(TEXT) TO anon, authenticated;

-- 11c. Adesão pelo link em UM passo, sem depender de confirmação de email nem de sessão.
--      Cria utilizador (já confirmado) + loja + perfil ADMIN + ligação ao embaixador.
DROP FUNCTION IF EXISTS public.fn_public_ambassador_signup(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.fn_public_ambassador_signup(
    p_referral_code TEXT,
    p_store_name TEXT,
    p_owner_name TEXT,
    p_phone TEXT,
    p_city TEXT,
    p_address TEXT,
    p_nuit_nif TEXT,
    p_monthly_fee NUMERIC,
    p_admin_email TEXT,
    p_admin_password TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, auth, pg_temp
AS $$
DECLARE
    v_amb public.ambassadors%ROWTYPE;
    v_store_id TEXT;
    v_code TEXT;
    v_uid UUID;
BEGIN
    SELECT * INTO v_amb
      FROM public.ambassadors
     WHERE UPPER(TRIM(referral_code)) = UPPER(TRIM(p_referral_code))
       AND COALESCE(status, CASE WHEN active THEN 'ATIVO' ELSE 'DESATIVADO' END) = 'ATIVO'
     LIMIT 1;
    IF v_amb.id IS NULL THEN RAISE EXCEPTION 'Link de embaixador inválido ou inativo.'; END IF;

    IF NULLIF(TRIM(p_store_name), '') IS NULL THEN RAISE EXCEPTION 'Nome da loja é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_owner_name), '') IS NULL THEN RAISE EXCEPTION 'Nome do responsável é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_phone), '') IS NULL THEN RAISE EXCEPTION 'Telefone é obrigatório.'; END IF;
    IF NULLIF(TRIM(p_city), '') IS NULL THEN RAISE EXCEPTION 'Cidade é obrigatória.'; END IF;

    v_store_id := 'store-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_code := 'REF-' || UPPER(SUBSTR(MD5(RANDOM()::TEXT || CLOCK_TIMESTAMP()::TEXT), 1, 8));

    INSERT INTO public.stores (
        id, code, name, trade_name, nuit_nif, city, address, phone,
        currency, language, is_headquarters,
        valor_mensalidade, data_inicio_teste, data_fim_teste, acesso_ativo
    ) VALUES (
        v_store_id, v_code, TRIM(p_store_name), TRIM(p_store_name),
        NULLIF(TRIM(p_nuit_nif), ''), TRIM(p_city), NULLIF(TRIM(p_address), ''), TRIM(p_phone),
        'MT', 'pt', FALSE,
        COALESCE(p_monthly_fee, 0), NOW(), CURRENT_DATE + 30, TRUE
    );

    v_uid := public.fn_internal_create_store_user(p_admin_email, p_admin_password, p_owner_name, 'ADMIN', v_store_id);

    INSERT INTO public.ambassador_referred_stores (
        id, store_id, ambassador_id, name, owner_name, phone, city,
        monthly_fee, payment_status, next_due_date,
        commission_rate, contract_duration_months, months_active, total_commission_earned
    ) VALUES (
        v_store_id, v_store_id, v_amb.id, TRIM(p_store_name), TRIM(p_owner_name), TRIM(p_phone), TRIM(p_city),
        COALESCE(p_monthly_fee, 0), 'PENDENTE', CURRENT_DATE + 30,
        COALESCE(v_amb.commission_rate, 15), 12, 0, 0
    );

    RETURN jsonb_build_object('success', TRUE, 'store_id', v_store_id, 'admin_user_id', v_uid);
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Não foi possível concluir o registo: já existem dados iguais (email ou loja).';
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_public_ambassador_signup(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT) TO anon, authenticated;
