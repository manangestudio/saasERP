-- =============================================================================
-- v11 — CATEGORIA + SUBCATEGORIA, IMAGEM DE FUNDO DA LOJA, DEPARTAMENTOS NA LOJA VIRTUAL
-- Executar no Supabase (SQL Editor) DEPOIS de migracao_loja_virtual_v10.sql e migracao_loja_virtual_v10_1_fix.sql.
-- Idempotente (pode correr mais de uma vez). Não apaga nem altera dados existentes.
--   1) products.subcategory (opcional)
--   2) fn_public_store    -> categorias com subcategorias e contagens (árvore)
--   3) fn_public_products -> filtro por subcategoria; a pesquisa também procura na subcategoria
--   4) fn_public_product  -> devolve a subcategoria
--   5) fn_vstore_save_config -> aceita bg_path (imagem de fundo)
-- As funções públicas ficam VOLATILE (fazem INSERT no limitador de pedidos).
-- =============================================================================

ALTER TABLE public.products ADD COLUMN IF NOT EXISTS subcategory TEXT;
CREATE INDEX IF NOT EXISTS idx_products_store_cat_sub ON public.products(store_id, category, subcategory) WHERE published;

-- Pesquisa sem distinção de maiúsculas nem acentos ("aco" encontra "Aço")
CREATE OR REPLACE FUNCTION public.fn_norm(p TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(lower(COALESCE(p, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn');
$$;

-- 2)
CREATE OR REPLACE FUNCTION public.fn_public_store(p_slug TEXT) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE; v_theme TEXT;
BEGIN
    SELECT * INTO s FROM public.stores WHERE slug = lower(TRIM(COALESCE(p_slug, '')));
    IF s.id IS NULL THEN RETURN jsonb_build_object('ok', FALSE, 'code', 'NOT_FOUND'); END IF;
    IF NOT s.vstore_enabled OR COALESCE(s.acesso_ativo, TRUE) = FALSE THEN
        RETURN jsonb_build_object('ok', FALSE, 'code', 'DISABLED', 'name', COALESCE(s.trade_name, s.name));
    END IF;
    PERFORM public.fn_rate_limit('pstore:' || public.fn_client_ip(), 120, 60);
    SELECT id INTO v_theme FROM public.vstore_themes WHERE id = s.vstore_theme AND enabled;
    RETURN jsonb_build_object('ok', TRUE, 'slug', s.slug, 'name', COALESCE(s.trade_name, s.name), 'city', s.city, 'province', s.province,
        'address', s.address, 'phone', s.phone, 'email', s.email, 'currency', COALESCE(s.currency, 'MT'), 'language', COALESCE(s.language, 'pt'),
        'theme', COALESCE(v_theme, 'classico'), 'config', s.vstore_config,
        'categories', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', c.category, 'count', c.n, 'subs', c.subs) ORDER BY c.category)
                                  FROM (SELECT p.category, COUNT(*) AS n,
                                               COALESCE((SELECT jsonb_agg(jsonb_build_object('name', t.subcategory, 'count', t.n) ORDER BY t.subcategory)
                                                           FROM (SELECT x.subcategory, COUNT(*) AS n FROM public.products x
                                                                  WHERE x.store_id = s.id AND x.published AND COALESCE(x.active, TRUE) AND x.category = p.category
                                                                    AND NULLIF(TRIM(COALESCE(x.subcategory, '')), '') IS NOT NULL GROUP BY x.subcategory) t), '[]'::JSONB) AS subs
                                          FROM public.products p WHERE p.store_id = s.id AND p.published AND COALESCE(p.active, TRUE) GROUP BY p.category) c
                                 WHERE NOT (COALESCE(s.vstore_config -> 'categories_hidden', '[]'::JSONB) ? c.category)), '[]'::JSONB));
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_store(TEXT) TO anon, authenticated;

-- 3) (a assinatura muda: remove a antiga para não ficarem duas versões)
DROP FUNCTION IF EXISTS public.fn_public_products(TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, INT);
CREATE OR REPLACE FUNCTION public.fn_public_products(
    p_slug TEXT, p_q TEXT DEFAULT NULL, p_category TEXT DEFAULT NULL, p_sort TEXT DEFAULT 'recent',
    p_only_promo BOOLEAN DEFAULT FALSE, p_featured BOOLEAN DEFAULT FALSE, p_cursor TEXT DEFAULT NULL, p_limit INT DEFAULT 24, p_subcategory TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    s public.stores%ROWTYPE; v_lim INT := LEAST(GREATEST(COALESCE(p_limit, 24), 1), 24);
    v_expr TEXT; v_type TEXT; v_dir TEXT; v_op TEXT; v_where TEXT := ''; v_pat TEXT; v_cur JSONB; v_sql TEXT; v_rows JSONB; v_next TEXT;
BEGIN
    s := public.fn_vstore_resolve(p_slug);
    PERFORM public.fn_rate_limit('psearch:' || public.fn_client_ip() || ':' || s.id, 90, 60);
    IF p_featured THEN v_expr := 'COALESCE(p.featured_order, 9999)'; v_type := 'int'; v_dir := 'ASC'; v_op := '>';
    ELSIF p_sort = 'name' THEN v_expr := 'lower(p.name)'; v_type := 'text'; v_dir := 'ASC'; v_op := '>';
    ELSIF p_sort = 'price_asc' THEN v_expr := 'public.fn_effective_price(p)'; v_type := 'numeric'; v_dir := 'ASC'; v_op := '>';
    ELSIF p_sort = 'price_desc' THEN v_expr := 'public.fn_effective_price(p)'; v_type := 'numeric'; v_dir := 'DESC'; v_op := '<';
    ELSE v_expr := 'p.created_at'; v_type := 'timestamptz'; v_dir := 'DESC'; v_op := '<'; END IF;

    IF NULLIF(TRIM(COALESCE(p_q, '')), '') IS NOT NULL THEN
        v_pat := '%' || public.fn_norm(replace(replace(replace(LEFT(TRIM(p_q), 60), '\', '\\'), '%', '\%'), '_', '\_')) || '%';
        v_where := v_where || format(' AND (public.fn_norm(p.name) LIKE %1$L OR public.fn_norm(p.brand) LIKE %1$L OR public.fn_norm(p.model) LIKE %1$L OR public.fn_norm(p.code) LIKE %1$L OR public.fn_norm(p.category) LIKE %1$L OR public.fn_norm(p.subcategory) LIKE %1$L)', v_pat);
    END IF;
    IF NULLIF(TRIM(COALESCE(p_category, '')), '') IS NOT NULL THEN v_where := v_where || format(' AND p.category = %L', p_category); END IF;
    IF NULLIF(TRIM(COALESCE(p_subcategory, '')), '') IS NOT NULL THEN v_where := v_where || format(' AND p.subcategory = %L', p_subcategory); END IF;
    IF p_only_promo THEN v_where := v_where || ' AND public.fn_effective_price(p) < p.sale_price'; END IF;
    IF p_featured THEN v_where := v_where || ' AND p.featured'; END IF;
    IF NULLIF(COALESCE(p_cursor, ''), '') IS NOT NULL THEN
        BEGIN v_cur := p_cursor::JSONB; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Cursor inválido.'; END;
        v_where := v_where || format(' AND (%s, p.id) %s (%L::%s, %L)', v_expr, v_op, v_cur ->> 'k', v_type, v_cur ->> 'id');
    END IF;

    v_sql := format($q$
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.rn), '[]'::JSONB) FROM (
            SELECT row_number() OVER (ORDER BY %1$s %2$s, p.id %2$s) AS rn, p.id, p.name, p.category, p.subcategory, p.brand, p.unit, p.has_colors,
                   p.sale_price AS price, public.fn_effective_price(p) AS effective_price, (public.fn_effective_price(p) < p.sale_price) AS on_promo, p.featured,
                   (SELECT i.path FROM public.product_images i WHERE i.product_id = p.id ORDER BY i.is_main DESC, i.sort_order, i.created_at LIMIT 1) AS image,
                   (SELECT i.thumb_path FROM public.product_images i WHERE i.product_id = p.id ORDER BY i.is_main DESC, i.sort_order, i.created_at LIMIT 1) AS thumb,
                   CASE WHEN p.has_colors THEN EXISTS (SELECT 1 FROM public.product_colors c WHERE c.product_id = p.id AND c.available AND (c.stock_qty IS NULL OR c.stock_qty > 0))
                        ELSE COALESCE(p.current_stock, 0) > 0 END AS available,
                   (%1$s)::text AS sk
              FROM public.products p
             WHERE p.store_id = %3$L AND p.published AND COALESCE(p.active, TRUE) %4$s
             ORDER BY %1$s %2$s, p.id %2$s LIMIT %5$s) x $q$, v_expr, v_dir, s.id, v_where, v_lim + 1);
    EXECUTE v_sql INTO v_rows;

    IF jsonb_array_length(v_rows) > v_lim THEN
        v_next := jsonb_build_object('k', v_rows -> (v_lim - 1) ->> 'sk', 'id', v_rows -> (v_lim - 1) ->> 'id')::TEXT;
        SELECT COALESCE(jsonb_agg(e), '[]'::JSONB) INTO v_rows FROM (SELECT e FROM jsonb_array_elements(v_rows) WITH ORDINALITY t(e, n) WHERE n <= v_lim ORDER BY n) z;
    END IF;
    RETURN jsonb_build_object('ok', TRUE, 'items', v_rows, 'next_cursor', v_next);
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_products(TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, INT, TEXT) TO anon, authenticated;

-- 4)
CREATE OR REPLACE FUNCTION public.fn_public_product(p_slug TEXT, p_product_id TEXT) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE; p public.products%ROWTYPE;
BEGIN
    BEGIN s := public.fn_vstore_resolve(p_slug);
    EXCEPTION WHEN SQLSTATE 'P0002' THEN RETURN jsonb_build_object('ok', FALSE, 'code', 'STORE_UNAVAILABLE'); END;
    PERFORM public.fn_rate_limit('pproduct:' || public.fn_client_ip() || ':' || s.id, 120, 60);
    SELECT * INTO p FROM public.products WHERE id = p_product_id AND store_id = s.id;
    IF p.id IS NULL THEN RETURN jsonb_build_object('ok', FALSE, 'code', 'NOT_FOUND'); END IF;
    IF NOT p.published OR COALESCE(p.active, TRUE) = FALSE THEN
        RETURN jsonb_build_object('ok', FALSE, 'code', 'UNPUBLISHED', 'name', p.name); -- sem expor detalhes
    END IF;
    RETURN jsonb_build_object('ok', TRUE, 'id', p.id, 'name', p.name, 'code', p.code, 'category', p.category, 'subcategory', p.subcategory, 'brand', p.brand, 'model', p.model,
        'unit', COALESCE(p.sale_unit, p.unit), 'description', p.description, 'details', p.details, 'notes', p.notes,
        'price', p.sale_price, 'effective_price', public.fn_effective_price(p), 'on_promo', public.fn_effective_price(p) < p.sale_price,
        'promo_end', CASE WHEN public.fn_effective_price(p) < p.sale_price THEN p.promo_end END,
        'has_colors', p.has_colors, 'color_required', p.color_required, 'is_fractional', COALESCE(p.is_fractional, FALSE),
        'available', CASE WHEN p.has_colors THEN EXISTS (SELECT 1 FROM public.product_colors c WHERE c.product_id = p.id AND c.available AND (c.stock_qty IS NULL OR c.stock_qty > 0))
                          ELSE COALESCE(p.current_stock, 0) > 0 END,
        'images', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'path', i.path, 'thumb', i.thumb_path, 'main', i.is_main) ORDER BY i.is_main DESC, i.sort_order, i.created_at)
                              FROM public.product_images i WHERE i.product_id = p.id), '[]'::JSONB),
        'colors', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'hex', c.hex, 'image_id', c.image_id,
                                'available', (c.available AND (c.stock_qty IS NULL OR c.stock_qty > 0))) ORDER BY c.sort_order, c.name)
                              FROM public.product_colors c WHERE c.product_id = p.id), '[]'::JSONB));
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_product(TEXT, TEXT) TO anon, authenticated;

-- 5)
CREATE OR REPLACE FUNCTION public.fn_vstore_save_config(p_theme TEXT, p_config JSONB) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']); v_cfg JSONB; v_sections JSONB;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.vstore_themes WHERE id = p_theme AND enabled) THEN RAISE EXCEPTION 'Tema não disponível.'; END IF;
    SELECT COALESCE(jsonb_agg(x ORDER BY n), '[]'::JSONB) INTO v_sections
      FROM (SELECT x, n FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_config -> 'sections') = 'array' THEN p_config -> 'sections' ELSE '[]'::JSONB END) WITH ORDINALITY t(x, n)
             WHERE x IN ('promos', 'featured', 'categories', 'catalog') LIMIT 4) z;
    v_cfg := jsonb_strip_nulls(jsonb_build_object(
        'primary', CASE WHEN p_config ->> 'primary' ~ '^#[0-9A-Fa-f]{6}$' THEN p_config ->> 'primary' END,
        'accent', CASE WHEN p_config ->> 'accent' ~ '^#[0-9A-Fa-f]{6}$' THEN p_config ->> 'accent' END,
        'tagline', NULLIF(LEFT(TRIM(COALESCE(p_config ->> 'tagline', '')), 160), ''),
        'about', NULLIF(LEFT(TRIM(COALESCE(p_config ->> 'about', '')), 600), ''),
        'whatsapp', NULLIF(LEFT(regexp_replace(COALESCE(p_config ->> 'whatsapp', ''), '[^0-9]', '', 'g'), 20), ''),
        'logo_path', CASE WHEN COALESCE(p_config ->> 'logo_path', '') LIKE v_store || '/%' THEN p_config ->> 'logo_path' END,
        'hero_path', CASE WHEN COALESCE(p_config ->> 'hero_path', '') LIKE v_store || '/%' THEN p_config ->> 'hero_path' END,
        'bg_path', CASE WHEN COALESCE(p_config ->> 'bg_path', '') LIKE v_store || '/%' THEN p_config ->> 'bg_path' END,
        'sections', CASE WHEN jsonb_array_length(v_sections) > 0 THEN v_sections END,
        'categories_hidden', CASE WHEN jsonb_typeof(p_config -> 'categories_hidden') = 'array' THEN (SELECT jsonb_agg(LEFT(x, 60)) FROM (SELECT x FROM jsonb_array_elements_text(p_config -> 'categories_hidden') x LIMIT 50) q) END));
    UPDATE public.stores SET vstore_theme = p_theme, vstore_config = v_cfg, updated_at = NOW() WHERE id = v_store;
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_vstore_save_config(TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_vstore_save_config(TEXT, JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Verificação (provolatile deve ser 'v'):
-- SELECT proname, provolatile FROM pg_proc WHERE proname IN ('fn_public_store','fn_public_products','fn_public_product');
