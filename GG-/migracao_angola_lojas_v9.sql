-- ==============================================================================
-- GEF | MIGRAÇÃO v9: formas de pagamento de Angola + Super Admin gere lojas e utilizadores (idempotente)
-- Pré-requisito: v2..v7 executadas. Sem DROP ... CASCADE; não apaga dados.
--  1. Vendas aceitam as formas Multicaixa Express, Referência Multicaixa e Carteira móvel
--  2. Lojas criadas por embaixadores passam a herdar a moeda/idioma do embaixador (antes: sempre MT/pt)
--  3. SUPERADMIN: criar loja (+ administrador, + embaixador opcional), editar loja, criar/editar utilizadores,
--     repor palavra-passe. Tudo validado no servidor e auditado em ambassador_audit_log.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Constraint de payment_method em public.sales (nome automático -> procura-se por definição)
-- ------------------------------------------------------------------------------
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT c.conname FROM pg_constraint c
              WHERE c.conrelid = 'public.sales'::regclass AND c.contype = 'c'
                AND pg_get_constraintdef(c.oid) ILIKE '%payment_method%' AND c.conname <> 'sales_payment_method_check_v9' LOOP
        EXECUTE format('ALTER TABLE public.sales DROP CONSTRAINT %I', r.conname);
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.sales'::regclass AND conname = 'sales_payment_method_check_v9') THEN
        ALTER TABLE public.sales ADD CONSTRAINT sales_payment_method_check_v9 CHECK (payment_method IN (
            'DINHEIRO', 'M-PESA', 'E-MOLA', 'POS_CARTAO', 'TRANSFERENCIA', 'A_PRAZO', 'FIADO', 'CREDITO_FIADO', 'MULTIPLE',
            'MULTICAIXA_EXPRESS', 'REFERENCIA_MULTICAIXA', 'CARTEIRA_MOVEL'));
    END IF;
END $$;

-- ------------------------------------------------------------------------------
-- 3. SUPERADMIN: gestão de lojas e utilizadores
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_admin_create_store(
    p_name TEXT, p_trade_name TEXT, p_owner_name TEXT, p_phone TEXT, p_city TEXT, p_province TEXT, p_address TEXT,
    p_nuit_nif TEXT, p_email TEXT, p_currency TEXT, p_language TEXT, p_monthly_fee NUMERIC, p_trial_days INT,
    p_admin_email TEXT, p_admin_password TEXT, p_admin_name TEXT,
    p_ambassador_id TEXT DEFAULT NULL, p_contract_months INT DEFAULT 12)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, auth, pg_temp AS $$
DECLARE v_store_id TEXT; v_code TEXT; v_uid UUID; v_amb public.ambassadors%ROWTYPE; v_days INT := COALESCE(p_trial_days, 30);
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome da loja é obrigatório.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_phone, '')), '') IS NULL THEN RAISE EXCEPTION 'Telefone é obrigatório.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_city, '')), '') IS NULL THEN RAISE EXCEPTION 'Cidade é obrigatória.'; END IF;
    IF NOT public.fn_valid_currency(p_currency) THEN RAISE EXCEPTION 'Seleccione a moeda da loja.'; END IF;
    IF NOT public.fn_valid_language(p_language) THEN RAISE EXCEPTION 'Seleccione o idioma da loja.'; END IF;
    IF COALESCE(p_monthly_fee, 0) < 0 THEN RAISE EXCEPTION 'Mensalidade inválida.'; END IF;
    IF v_days < 0 OR v_days > 3650 THEN RAISE EXCEPTION 'Período inicial inválido.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_admin_email, '')), '') IS NULL OR p_admin_password IS NULL THEN RAISE EXCEPTION 'Indique email e palavra-passe do administrador da loja.'; END IF;

    IF NULLIF(TRIM(COALESCE(p_ambassador_id, '')), '') IS NOT NULL THEN
        SELECT * INTO v_amb FROM public.ambassadors WHERE id = p_ambassador_id AND deleted_at IS NULL;
        IF v_amb.id IS NULL OR COALESCE(v_amb.status, 'ATIVO') <> 'ATIVO' THEN RAISE EXCEPTION 'O embaixador escolhido não existe ou não está activo.'; END IF;
    END IF;

    v_store_id := 'store-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_code := 'LJ-' || UPPER(SUBSTR(MD5(RANDOM()::TEXT || CLOCK_TIMESTAMP()::TEXT), 1, 8));

    INSERT INTO public.stores (id, code, name, trade_name, nuit_nif, city, province, address, phone, email, currency, language,
                               is_headquarters, valor_mensalidade, data_inicio_teste, data_fim_teste, acesso_ativo)
    VALUES (v_store_id, v_code, TRIM(p_name), COALESCE(NULLIF(TRIM(COALESCE(p_trade_name, '')), ''), TRIM(p_name)),
            NULLIF(TRIM(COALESCE(p_nuit_nif, '')), ''), TRIM(p_city), NULLIF(TRIM(COALESCE(p_province, '')), ''),
            NULLIF(TRIM(COALESCE(p_address, '')), ''), TRIM(p_phone), NULLIF(TRIM(COALESCE(p_email, '')), ''), p_currency, p_language,
            FALSE, COALESCE(p_monthly_fee, 0), NOW(), CURRENT_DATE + v_days, TRUE);

    v_uid := public.fn_internal_create_store_user(p_admin_email, p_admin_password,
                COALESCE(NULLIF(TRIM(COALESCE(p_admin_name, '')), ''), NULLIF(TRIM(COALESCE(p_owner_name, '')), ''), TRIM(p_name)), 'ADMIN', v_store_id);

    IF v_amb.id IS NOT NULL THEN
        INSERT INTO public.ambassador_referred_stores (id, store_id, ambassador_id, name, owner_name, phone, city, monthly_fee, payment_status,
                                                       next_due_date, commission_rate, contract_duration_months, months_active, total_commission_earned)
        VALUES (v_store_id, v_store_id, v_amb.id, TRIM(p_name), COALESCE(NULLIF(TRIM(COALESCE(p_owner_name, '')), ''), TRIM(p_name)), TRIM(p_phone), TRIM(p_city),
                COALESCE(p_monthly_fee, 0), 'PENDENTE', CURRENT_DATE + v_days, COALESCE(v_amb.commission_rate, 15),
                COALESCE(NULLIF(p_contract_months, 0), 12), 0, 0);
    END IF;

    PERFORM public.fn_amb_audit('STORE_CREATED', v_amb.id, v_store_id, NULL,
        jsonb_build_object('name', TRIM(p_name), 'currency', p_currency, 'language', p_language, 'monthly_fee', COALESCE(p_monthly_fee, 0), 'ambassador', v_amb.id, 'admin_user', v_uid));
    RETURN jsonb_build_object('success', TRUE, 'store_id', v_store_id, 'store_code', v_code, 'admin_user_id', v_uid);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_create_store(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, INT, TEXT, TEXT, TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_create_store(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, INT, TEXT, TEXT, TEXT, TEXT, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_update_store(
    p_store_id TEXT, p_name TEXT, p_trade_name TEXT, p_nuit_nif TEXT, p_city TEXT, p_province TEXT, p_address TEXT,
    p_phone TEXT, p_email TEXT, p_currency TEXT, p_language TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome da loja é obrigatório.'; END IF;
    IF NOT public.fn_valid_currency(p_currency) THEN RAISE EXCEPTION 'Seleccione a moeda da loja.'; END IF;
    IF NOT public.fn_valid_language(p_language) THEN RAISE EXCEPTION 'Seleccione o idioma da loja.'; END IF;
    SELECT * INTO s FROM public.stores WHERE id = p_store_id FOR UPDATE;
    IF s.id IS NULL THEN RAISE EXCEPTION 'Loja não encontrada.'; END IF;

    UPDATE public.stores
       SET name = TRIM(p_name), trade_name = NULLIF(TRIM(COALESCE(p_trade_name, '')), ''), nuit_nif = NULLIF(TRIM(COALESCE(p_nuit_nif, '')), ''),
           city = NULLIF(TRIM(COALESCE(p_city, '')), ''), province = NULLIF(TRIM(COALESCE(p_province, '')), ''),
           address = NULLIF(TRIM(COALESCE(p_address, '')), ''), phone = NULLIF(TRIM(COALESCE(p_phone, '')), ''),
           email = NULLIF(TRIM(COALESCE(p_email, '')), ''), currency = p_currency, language = p_language, updated_at = NOW()
     WHERE id = s.id;
    -- cópia de apresentação na ficha de indicação (não toca em valores nem comissões)
    UPDATE public.ambassador_referred_stores SET name = TRIM(p_name), phone = COALESCE(NULLIF(TRIM(COALESCE(p_phone, '')), ''), phone),
           city = COALESCE(NULLIF(TRIM(COALESCE(p_city, '')), ''), city)
     WHERE store_id = s.id;
    PERFORM public.fn_amb_audit('STORE_EDITED', NULL, s.id, NULL,
        jsonb_build_object('old', jsonb_build_object('name', s.name, 'city', s.city, 'currency', s.currency, 'language', s.language),
                           'new', jsonb_build_object('name', TRIM(p_name), 'city', p_city, 'currency', p_currency, 'language', p_language)));
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_update_store(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_update_store(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_list_store_users(p_store_id TEXT)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'email', p.email, 'full_name', p.full_name, 'role', p.role,
                     'active', COALESCE(p.active, TRUE), 'created_at', p.created_at) ORDER BY p.created_at)
                       FROM public.profiles p WHERE p.store_id = p_store_id), '[]'::JSONB);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_list_store_users(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_list_store_users(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_create_store_user(p_store_id TEXT, p_email TEXT, p_password TEXT, p_full_name TEXT, p_role TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, auth, pg_temp AS $$
DECLARE v_uid UUID; v_role TEXT := UPPER(TRIM(COALESCE(p_role, '')));
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF v_role NOT IN ('ADMIN', 'GERENTE', 'CASHIER', 'ESTOQUISTA') THEN RAISE EXCEPTION 'Função inválida para utilizador de loja.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_full_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome é obrigatório.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.stores WHERE id = p_store_id) THEN RAISE EXCEPTION 'Loja não encontrada.'; END IF;
    v_uid := public.fn_internal_create_store_user(p_email, p_password, p_full_name, v_role, p_store_id);
    PERFORM public.fn_amb_audit('STORE_USER_CREATED', NULL, p_store_id, NULL, jsonb_build_object('user_id', v_uid, 'role', v_role, 'email', LOWER(TRIM(p_email))));
    RETURN jsonb_build_object('success', TRUE, 'user_id', v_uid);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_create_store_user(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_create_store_user(TEXT, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- Só utilizadores de loja (nunca SUPERADMIN nem EMBAIXADOR) podem ser editados por aqui.
CREATE OR REPLACE FUNCTION public.fn_admin_update_store_user(p_user_id UUID, p_full_name TEXT, p_role TEXT, p_active BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE u public.profiles%ROWTYPE; v_role TEXT := UPPER(TRIM(COALESCE(p_role, '')));
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF v_role NOT IN ('ADMIN', 'GERENTE', 'CASHIER', 'ESTOQUISTA') THEN RAISE EXCEPTION 'Função inválida para utilizador de loja.'; END IF;
    IF NULLIF(TRIM(COALESCE(p_full_name, '')), '') IS NULL THEN RAISE EXCEPTION 'Nome é obrigatório.'; END IF;
    SELECT * INTO u FROM public.profiles WHERE id = p_user_id FOR UPDATE;
    IF u.id IS NULL OR u.store_id IS NULL OR u.role NOT IN ('ADMIN', 'GERENTE', 'CASHIER', 'ESTOQUISTA') THEN
        RAISE EXCEPTION 'Utilizador de loja não encontrado.';
    END IF;
    UPDATE public.profiles SET full_name = TRIM(p_full_name), role = v_role, active = COALESCE(p_active, TRUE), updated_at = NOW() WHERE id = u.id;
    PERFORM public.fn_amb_audit('STORE_USER_EDITED', NULL, u.store_id, NULL,
        jsonb_build_object('user_id', u.id, 'old_role', u.role, 'new_role', v_role, 'old_active', u.active, 'new_active', COALESCE(p_active, TRUE)));
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_update_store_user(UUID, TEXT, TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_update_store_user(UUID, TEXT, TEXT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_reset_store_user_password(p_user_id UUID, p_password TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, auth, pg_temp AS $$
DECLARE u public.profiles%ROWTYPE;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF p_password IS NULL OR LENGTH(p_password) < 8 THEN RAISE EXCEPTION 'A palavra-passe deve ter pelo menos 8 caracteres.'; END IF;
    SELECT * INTO u FROM public.profiles WHERE id = p_user_id;
    IF u.id IS NULL OR u.store_id IS NULL OR u.role NOT IN ('ADMIN', 'GERENTE', 'CASHIER', 'ESTOQUISTA') THEN RAISE EXCEPTION 'Utilizador de loja não encontrado.'; END IF;
    UPDATE auth.users SET encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = NOW() WHERE id = u.id;
    PERFORM public.fn_amb_audit('STORE_USER_PASSWORD_RESET', NULL, u.store_id, NULL, jsonb_build_object('user_id', u.id)); -- nunca regista a palavra-passe
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_reset_store_user_password(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_reset_store_user_password(UUID, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 2. fn_ambassador_create_store (copiada da v2; única alteração: moeda/idioma da loja = os do embaixador)
--    Assim uma loja cadastrada por embaixador de Angola nasce em Kz e usa as formas de pagamento angolanas.
-- ------------------------------------------------------------------------------
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
        COALESCE(v_amb.currency, 'MT'), COALESCE(v_amb.language, 'pt'), FALSE,
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
