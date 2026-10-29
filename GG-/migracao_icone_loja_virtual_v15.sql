-- ==============================================================================
-- GEF | MIGRAÇÃO v15: ÍCONE PERSONALIZADO NA LOJA VIRTUAL PÚBLICA  (idempotente, sem DROP, não apaga nem altera dados)
--
-- Problema: o ícone personalizado grava-se em public.store_app_identity (migracao_identidade_pwa_v12.sql), mas essa
-- tabela e fn_app_identity_get só são acessíveis a utilizadores AUTENTICADOS. A loja virtual (loja.html) é pública
-- (visitantes anónimos), por isso nunca conseguia ler o ícone e mostrava sempre o padrão.
--
-- Solução: UMA função nova, só de leitura, para o papel anon/authenticated:
--     public.fn_public_store_identity(p_slug TEXT) RETURNS JSONB
--   * A loja é resolvida pelo endereço público (stores.slug), no servidor. Cada loja só recebe a SUA identidade.
--   * Só responde se a loja estiver activa (acesso_ativo) E com a loja virtual activada (vstore_enabled) — as mesmas
--     condições de fn_public_store. Caso contrário devolve {ok:false} (sem revelar nada).
--   * Devolve apenas dados já públicos por natureza (nome, caminhos dos ícones no bucket PÚBLICO 'product-images',
--     cores, versão). Não devolve store_id, updated_by, admin_can_edit nem nenhum campo interno.
--   * Usa o mesmo limitador de pedidos (fn_rate_limit) das restantes RPCs públicas (por isso é VOLATILE).
--
-- Pré-requisitos (já existentes no projecto): migracao_loja_virtual_v10.sql (stores.slug, vstore_enabled, fn_rate_limit,
-- fn_client_ip) e migracao_identidade_pwa_v12.sql (store_app_identity).
-- Não altera fn_public_store, políticas RLS, tabelas nem o Storage.
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.fn_public_store_identity(p_slug TEXT) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE; r public.store_app_identity%ROWTYPE;
BEGIN
    SELECT * INTO s FROM public.stores WHERE slug = lower(TRIM(COALESCE(p_slug, '')));
    IF s.id IS NULL OR NOT s.vstore_enabled OR COALESCE(s.acesso_ativo, TRUE) = FALSE THEN
        RETURN jsonb_build_object('ok', FALSE);
    END IF;

    PERFORM public.fn_rate_limit('pident:' || public.fn_client_ip(), 120, 60);

    SELECT * INTO r FROM public.store_app_identity WHERE store_id = s.id;
    IF r.store_id IS NULL OR r.app_name IS NULL OR r.icon_192_path IS NULL THEN
        RETURN jsonb_build_object('ok', TRUE, 'configured', FALSE);
    END IF;

    RETURN jsonb_build_object(
        'ok', TRUE, 'configured', TRUE,
        'app_name', r.app_name, 'short_name', r.short_name,
        'logo_path', r.logo_path, 'icon_192_path', r.icon_192_path, 'icon_512_path', r.icon_512_path,
        'icon_maskable_path', r.icon_maskable_path, 'apple_icon_path', r.apple_icon_path,
        'theme_color', r.theme_color, 'background_color', r.background_color,
        'version', r.version, 'updated_at', r.updated_at);
END; $$;

REVOKE ALL ON FUNCTION public.fn_public_store_identity(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_public_store_identity(TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ------------------------------------------------------------------------------
-- Verificação (opcional). Substitua 'minha-loja' pelo endereço real da loja virtual:
--   SELECT proname, provolatile FROM pg_proc WHERE proname = 'fn_public_store_identity';   -- provolatile = 'v'
--   SELECT public.fn_public_store_identity('minha-loja');
--   -- loja com ícone configurado  -> {"ok":true,"configured":true,"app_name":...,"icon_192_path":"<loja>/identity/...png",...}
--   -- loja sem ícone configurado  -> {"ok":true,"configured":false}
--   -- endereço inexistente/desactivada -> {"ok":false}
-- ------------------------------------------------------------------------------
