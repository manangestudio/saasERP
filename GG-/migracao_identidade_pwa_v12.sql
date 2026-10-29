-- ==============================================================================
-- GEF | MIGRAÇÃO v12: IDENTIDADE DA APLICAÇÃO (PWA) POR LOJA  (idempotente, sem DROP, não apaga dados)
-- Pré-requisitos já existentes no projecto (verificados no schema real):
--   public.stores, public.profiles(id, role, store_id, active), public.get_auth_user_store_id(),
--   public.fn_is_superadmin() (v6), public.fn_rate_limit() (v10), bucket de Storage 'product-images' (v10).
-- Uma única base de dados: esta migração só ACRESCENTA a tabela store_app_identity (1 linha por loja) e 4 funções.
--
-- Segurança:
--   * RLS activa; SELECT só da própria loja (ou Super Admin). Nenhuma política de escrita: tudo se grava por funções
--     SECURITY DEFINER que validam sessão, perfil activo, papel, loja e caminhos de ficheiros.
--   * A loja é SEMPRE deduzida no servidor a partir de auth.uid() -> profiles.store_id. Nunca do e-mail nem de dados locais.
--   * Ficheiros: no bucket 'product-images', na pasta <loja>/identity/ (a política de Storage da v10 já restringe a escrita
--     à pasta da própria loja; o Super Admin escreve em qualquer uma). A função recusa caminhos fora dessa pasta.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.store_app_identity (
    store_id            TEXT PRIMARY KEY REFERENCES public.stores(id) ON DELETE CASCADE,
    app_name            TEXT CHECK (app_name IS NULL OR char_length(app_name) BETWEEN 1 AND 40),
    short_name          TEXT CHECK (short_name IS NULL OR char_length(short_name) BETWEEN 1 AND 12),
    logo_path           TEXT,
    icon_192_path       TEXT,
    icon_512_path       TEXT,
    icon_maskable_path  TEXT,
    apple_icon_path     TEXT,
    theme_color         TEXT NOT NULL DEFAULT '#020617' CHECK (theme_color ~ '^#[0-9A-Fa-f]{6}$'),
    background_color    TEXT NOT NULL DEFAULT '#020617' CHECK (background_color ~ '^#[0-9A-Fa-f]{6}$'),
    admin_can_edit      BOOLEAN NOT NULL DEFAULT TRUE,   -- o Super Admin pode retirar ao Administrador da loja o direito de editar
    version             INT NOT NULL DEFAULT 1,           -- sobe em cada gravação (serve para saber se a identidade mudou)
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by          UUID
);

ALTER TABLE public.store_app_identity ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "store_app_identity_select" ON public.store_app_identity;
CREATE POLICY "store_app_identity_select" ON public.store_app_identity FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());
REVOKE ALL ON public.store_app_identity FROM PUBLIC, anon;
GRANT SELECT ON public.store_app_identity TO authenticated;
-- Sem INSERT/UPDATE/DELETE para ninguém: as escritas passam só pelas funções abaixo.

-- ------------------------------------------------------------------------------
-- Leitura: identidade da loja do utilizador autenticado.
--   Super Admin: pode indicar p_store_id (para configurar/pré-visualizar qualquer loja).
--   Os restantes: p_store_id é IGNORADO; usa-se sempre a loja do próprio perfil.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_app_identity_get(p_store_id TEXT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pr public.profiles%ROWTYPE; v_store TEXT; r public.store_app_identity%ROWTYPE; v_name TEXT; v_can BOOLEAN;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;
    SELECT * INTO pr FROM public.profiles WHERE id = auth.uid();
    IF pr.id IS NULL OR COALESCE(pr.active, TRUE) = FALSE THEN RAISE EXCEPTION 'Perfil inexistente ou inactivo.'; END IF;

    IF pr.role = 'SUPERADMIN' THEN v_store := NULLIF(NULLIF(p_store_id, ''), 'ALL');
    ELSE v_store := pr.store_id; END IF;
    IF v_store IS NULL THEN RETURN jsonb_build_object('store_id', NULL, 'configured', FALSE, 'can_edit', FALSE); END IF;

    SELECT name INTO v_name FROM public.stores WHERE id = v_store;
    IF v_name IS NULL THEN RETURN jsonb_build_object('store_id', NULL, 'configured', FALSE, 'can_edit', FALSE); END IF;

    SELECT * INTO r FROM public.store_app_identity WHERE store_id = v_store;
    v_can := pr.role = 'SUPERADMIN' OR (pr.role = 'ADMIN' AND COALESCE(r.admin_can_edit, TRUE));
    RETURN jsonb_build_object(
        'store_id', v_store, 'store_name', v_name,
        'configured', r.app_name IS NOT NULL,
        'app_name', r.app_name, 'short_name', r.short_name,
        'logo_path', r.logo_path, 'icon_192_path', r.icon_192_path, 'icon_512_path', r.icon_512_path,
        'icon_maskable_path', r.icon_maskable_path, 'apple_icon_path', r.apple_icon_path,
        'theme_color', COALESCE(r.theme_color, '#020617'), 'background_color', COALESCE(r.background_color, '#020617'),
        'admin_can_edit', COALESCE(r.admin_can_edit, TRUE), 'can_edit', v_can,
        'version', COALESCE(r.version, 0), 'updated_at', r.updated_at);
END; $$;
REVOKE ALL ON FUNCTION public.fn_app_identity_get(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_app_identity_get(TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- Gravação. p_data: { app_name, short_name, theme_color, background_color, logo_path, icon_192_path, icon_512_path,
--                     icon_maskable_path, apple_icon_path }   ou   { "reset": true } para voltar ao padrão GEF.
-- Devolve também old_paths (ficheiros que deixaram de ser usados) para o cliente os apagar do Storage.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_app_identity_save(p_store_id TEXT, p_data JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    pr public.profiles%ROWTYPE; v_store TEXT; old public.store_app_identity%ROWTYPE;
    v_name TEXT; v_short TEXT; v_theme TEXT; v_bg TEXT; k TEXT; v TEXT;
    v_paths JSONB := '{}'::JSONB; v_old TEXT[] := ARRAY[]::TEXT[]; v_new_list TEXT[] := ARRAY[]::TEXT[];
    v_version INT;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;
    SELECT * INTO pr FROM public.profiles WHERE id = auth.uid();
    IF pr.id IS NULL OR COALESCE(pr.active, TRUE) = FALSE THEN RAISE EXCEPTION 'Perfil inexistente ou inactivo.'; END IF;
    IF pr.role NOT IN ('SUPERADMIN', 'ADMIN') THEN RAISE EXCEPTION 'Sem permissão para alterar a identidade da aplicação.'; END IF;

    IF pr.role = 'SUPERADMIN' THEN v_store := NULLIF(NULLIF(p_store_id, ''), 'ALL');
    ELSE
        v_store := pr.store_id;
        IF NULLIF(p_store_id, '') IS NOT NULL AND p_store_id <> v_store THEN RAISE EXCEPTION 'Só pode configurar a identidade da sua própria loja.'; END IF;
    END IF;
    IF v_store IS NULL OR NOT EXISTS (SELECT 1 FROM public.stores WHERE id = v_store) THEN RAISE EXCEPTION 'Loja inválida.'; END IF;

    PERFORM public.fn_rate_limit('appid:' || auth.uid()::TEXT, 30, 60);
    INSERT INTO public.store_app_identity (store_id) VALUES (v_store) ON CONFLICT (store_id) DO NOTHING;
    SELECT * INTO old FROM public.store_app_identity WHERE store_id = v_store FOR UPDATE;
    IF pr.role = 'ADMIN' AND NOT old.admin_can_edit THEN RAISE EXCEPTION 'O Super Administrador não autorizou esta loja a alterar a identidade da aplicação.'; END IF;

    v_old := ARRAY[old.logo_path, old.icon_192_path, old.icon_512_path, old.icon_maskable_path, old.apple_icon_path];

    IF COALESCE((p_data ->> 'reset')::BOOLEAN, FALSE) THEN
        UPDATE public.store_app_identity SET app_name = NULL, short_name = NULL, logo_path = NULL, icon_192_path = NULL, icon_512_path = NULL,
               icon_maskable_path = NULL, apple_icon_path = NULL, theme_color = '#020617', background_color = '#020617',
               version = version + 1, updated_at = NOW(), updated_by = auth.uid()
         WHERE store_id = v_store RETURNING version INTO v_version;
        RETURN jsonb_build_object('success', TRUE, 'version', v_version, 'old_paths', to_jsonb(ARRAY(SELECT x FROM unnest(v_old) x WHERE x IS NOT NULL)));
    END IF;

    v_name := TRIM(regexp_replace(COALESCE(p_data ->> 'app_name', ''), '[[:cntrl:]<>]', '', 'g'));
    v_short := TRIM(regexp_replace(COALESCE(p_data ->> 'short_name', ''), '[[:cntrl:]<>]', '', 'g'));
    IF char_length(v_name) < 1 OR char_length(v_name) > 40 THEN RAISE EXCEPTION 'O nome da aplicação deve ter entre 1 e 40 caracteres.'; END IF;
    IF char_length(v_short) < 1 OR char_length(v_short) > 12 THEN RAISE EXCEPTION 'O nome curto deve ter entre 1 e 12 caracteres.'; END IF;
    v_theme := COALESCE(p_data ->> 'theme_color', '#020617'); v_bg := COALESCE(p_data ->> 'background_color', '#020617');
    IF v_theme !~ '^#[0-9A-Fa-f]{6}$' OR v_bg !~ '^#[0-9A-Fa-f]{6}$' THEN RAISE EXCEPTION 'Cor inválida (use o formato #RRGGBB).'; END IF;

    FOREACH k IN ARRAY ARRAY['logo_path', 'icon_192_path', 'icon_512_path', 'icon_maskable_path', 'apple_icon_path'] LOOP
        v := NULLIF(p_data ->> k, '');
        IF v IS NOT NULL THEN
            IF v NOT LIKE v_store || '/identity/%' OR v LIKE '%..%' OR char_length(v) > 300 THEN RAISE EXCEPTION 'Caminho de ficheiro inválido (%).', k; END IF;
            v_new_list := v_new_list || v;
        END IF;
        v_paths := v_paths || jsonb_build_object(k, v);
    END LOOP;
    IF (v_paths ->> 'icon_192_path') IS NULL OR (v_paths ->> 'icon_512_path') IS NULL THEN
        RAISE EXCEPTION 'São necessários os ícones de 192 e 512 px (carregue um logótipo ou ícone).';
    END IF;

    UPDATE public.store_app_identity SET
        app_name = v_name, short_name = v_short, theme_color = v_theme, background_color = v_bg,
        logo_path = v_paths ->> 'logo_path', icon_192_path = v_paths ->> 'icon_192_path', icon_512_path = v_paths ->> 'icon_512_path',
        icon_maskable_path = v_paths ->> 'icon_maskable_path', apple_icon_path = v_paths ->> 'apple_icon_path',
        version = version + 1, updated_at = NOW(), updated_by = auth.uid()
     WHERE store_id = v_store RETURNING version INTO v_version;

    RETURN jsonb_build_object('success', TRUE, 'version', v_version,
        'old_paths', to_jsonb(ARRAY(SELECT x FROM unnest(v_old) x WHERE x IS NOT NULL AND NOT (x = ANY (v_new_list)))));
END; $$;
REVOKE ALL ON FUNCTION public.fn_app_identity_save(TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_app_identity_save(TEXT, JSONB) TO authenticated;

-- ------------------------------------------------------------------------------
-- Só o Super Admin decide se o Administrador de uma loja pode editar a identidade da sua aplicação.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_app_identity_set_admin_edit(p_store_id TEXT, p_allowed BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    IF p_store_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.stores WHERE id = p_store_id) THEN RAISE EXCEPTION 'Loja inválida.'; END IF;
    INSERT INTO public.store_app_identity (store_id, admin_can_edit, updated_by) VALUES (p_store_id, COALESCE(p_allowed, TRUE), auth.uid())
    ON CONFLICT (store_id) DO UPDATE SET admin_can_edit = COALESCE(p_allowed, TRUE), updated_at = NOW(), updated_by = auth.uid();
    RETURN jsonb_build_object('success', TRUE, 'admin_can_edit', COALESCE(p_allowed, TRUE));
END; $$;
REVOKE ALL ON FUNCTION public.fn_app_identity_set_admin_edit(TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_app_identity_set_admin_edit(TEXT, BOOLEAN) TO authenticated;

-- ------------------------------------------------------------------------------
-- Verificação rápida (opcional): deve devolver as 4 funções e a tabela com RLS activa.
-- ------------------------------------------------------------------------------
-- SELECT proname FROM pg_proc WHERE proname LIKE 'fn_app_identity_%';
-- SELECT relname, relrowsecurity FROM pg_class WHERE relname = 'store_app_identity';
