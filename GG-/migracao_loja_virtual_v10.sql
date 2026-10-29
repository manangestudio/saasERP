-- ==============================================================================
-- GEF | MIGRAÇÃO v10: LOJA VIRTUAL, FOTOS, CORES, ENCOMENDAS E COTAÇÕES ONLINE (idempotente)
-- Pré-requisitos: schema base + v7 (fn_amb_audit, fn_is_superadmin) + v9. Sem DROP CASCADE, não apaga dados.
-- Reutiliza public.products / public.quotes / public.stores (nada de catálogo paralelo).
--  1. stores: slug permanente + estado SEPARADO da loja virtual + tema/configuração
--  2. products: campos comerciais, publicação, promoção com validade, destaque, cores
--  3. product_images (máx. por produto numa única constante), product_colors
--  4. Storage (bucket público de imagens, escrita só na pasta da própria loja)
--  5. Encomendas online (web_orders / web_order_items) — NÃO são vendas nem pagamentos
--  6. Rate limiting no servidor (api_rate_limits + fn_rate_limit)
--  7. RPCs públicas (anon): loja, catálogo (keyset), produto, encomenda, cotação
--  8. RPCs da loja (ADMIN/GERENTE/ESTOQUISTA): configuração, produto, fotos, cores, encomendas
--  9. RPCs do Super Admin: activar/suspender loja virtual, temas, visão global
-- 10. Índices de desempenho
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- Constante: nº máximo de fotografias por produto (ALTERAR AQUI se quiser outro limite)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_max_product_images() RETURNS INT LANGUAGE sql IMMUTABLE AS $$ SELECT 5; $$;

-- ------------------------------------------------------------------------------
-- 1. STORES
-- ------------------------------------------------------------------------------
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS slug TEXT;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS vstore_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS vstore_theme TEXT NOT NULL DEFAULT 'classico';
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS vstore_config JSONB NOT NULL DEFAULT '{}'::JSONB;

CREATE OR REPLACE FUNCTION public.fn_make_slug(p TEXT) RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(NULLIF(TRIM(BOTH '-' FROM regexp_replace(
        translate(lower(COALESCE(p, '')), 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]+', '-', 'g')), ''), 'loja');
$$;

CREATE OR REPLACE FUNCTION public.fn_unique_slug(p_name TEXT, p_store_id TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE v_base TEXT := LEFT(public.fn_make_slug(p_name), 48); v TEXT; n INT := 1;
BEGIN
    v := v_base;
    WHILE EXISTS (SELECT 1 FROM public.stores WHERE slug = v AND id IS DISTINCT FROM p_store_id) LOOP
        n := n + 1; v := v_base || '-' || n;
    END LOOP;
    RETURN v;
END; $$;

DO $$ DECLARE r RECORD;
BEGIN
    FOR r IN SELECT id, COALESCE(trade_name, name) AS n FROM public.stores WHERE slug IS NULL ORDER BY created_at LOOP
        UPDATE public.stores SET slug = public.fn_unique_slug(r.n, r.id) WHERE id = r.id;
    END LOOP;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS uq_stores_slug ON public.stores(slug) WHERE slug IS NOT NULL;

CREATE OR REPLACE FUNCTION public.fn_stores_assign_slug() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.slug IS NULL OR NEW.slug = '' THEN NEW.slug := public.fn_unique_slug(COALESCE(NEW.trade_name, NEW.name), NEW.id); END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_stores_assign_slug ON public.stores;
CREATE TRIGGER trg_stores_assign_slug BEFORE INSERT ON public.stores FOR EACH ROW EXECUTE FUNCTION public.fn_stores_assign_slug();

-- Só o SUPERADMIN muda o endereço permanente e o estado da loja virtual (mesmo por API directa).
CREATE OR REPLACE FUNCTION public.fn_protect_vstore_fields() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF auth.uid() IS NOT NULL AND public.get_auth_user_role() IS DISTINCT FROM 'SUPERADMIN' THEN
        NEW.slug := OLD.slug;
        NEW.vstore_enabled := OLD.vstore_enabled;
    END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_protect_vstore_fields ON public.stores;
CREATE TRIGGER trg_protect_vstore_fields BEFORE UPDATE ON public.stores FOR EACH ROW EXECUTE FUNCTION public.fn_protect_vstore_fields();

-- Temas (o Super Admin controla quais estão disponíveis)
CREATE TABLE IF NOT EXISTS public.vstore_themes (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, enabled BOOLEAN NOT NULL DEFAULT TRUE, sort_order INT NOT NULL DEFAULT 0
);
ALTER TABLE public.vstore_themes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "vstore_themes_read" ON public.vstore_themes;
CREATE POLICY "vstore_themes_read" ON public.vstore_themes FOR SELECT TO authenticated USING (TRUE);
INSERT INTO public.vstore_themes (id, name, sort_order) VALUES
    ('classico', 'Clássico (azul)', 1), ('moderno', 'Moderno (escuro e laranja)', 2),
    ('natureza', 'Natureza (verde)', 3), ('minimal', 'Minimal (claro)', 4)
ON CONFLICT (id) DO NOTHING;

-- ------------------------------------------------------------------------------
-- 2. PRODUCTS (campos novos — todos opcionais)
-- ------------------------------------------------------------------------------
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS details TEXT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS brand TEXT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS model TEXT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS sale_unit TEXT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS published BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS promo_price NUMERIC(12, 2);
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS promo_start TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS promo_end TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS promo_active BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS featured BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS featured_order INT;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS has_colors BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS color_required BOOLEAN NOT NULL DEFAULT TRUE;

-- Preço aplicável AGORA (o preço base nunca é alterado para representar promoção).
CREATE OR REPLACE FUNCTION public.fn_effective_price(p public.products) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN COALESCE(p.promo_active, FALSE) AND p.promo_price IS NOT NULL AND p.promo_price >= 0 AND p.promo_price < p.sale_price
                 AND (p.promo_start IS NULL OR p.promo_start <= NOW()) AND (p.promo_end IS NULL OR p.promo_end >= NOW())
                THEN p.promo_price ELSE p.sale_price END;
$$;

-- ------------------------------------------------------------------------------
-- 3. FOTOGRAFIAS E CORES
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.product_images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    thumb_path TEXT,
    is_main BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order INT NOT NULL DEFAULT 0,
    size_bytes INT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_images_main ON public.product_images(product_id) WHERE is_main;
CREATE INDEX IF NOT EXISTS idx_product_images_product ON public.product_images(product_id, sort_order);

CREATE OR REPLACE FUNCTION public.fn_product_images_limit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT COUNT(*) FROM public.product_images WHERE product_id = NEW.product_id) >= public.fn_max_product_images() THEN
        RAISE EXCEPTION 'Cada produto aceita no máximo % fotografias.', public.fn_max_product_images();
    END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_product_images_limit ON public.product_images;
CREATE TRIGGER trg_product_images_limit BEFORE INSERT ON public.product_images FOR EACH ROW EXECUTE FUNCTION public.fn_product_images_limit();

CREATE TABLE IF NOT EXISTS public.product_colors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    hex TEXT CHECK (hex IS NULL OR hex ~ '^#[0-9A-Fa-f]{6}$'),
    available BOOLEAN NOT NULL DEFAULT TRUE,
    stock_qty NUMERIC(12, 2) CHECK (stock_qty IS NULL OR stock_qty >= 0),  -- NULL = não controla stock por cor
    image_id UUID REFERENCES public.product_images(id) ON DELETE SET NULL,
    sort_order INT NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_colors_name ON public.product_colors(product_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_product_colors_product ON public.product_colors(product_id, sort_order);

ALTER TABLE public.product_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_colors ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "product_images_store_select" ON public.product_images;
CREATE POLICY "product_images_store_select" ON public.product_images FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());
DROP POLICY IF EXISTS "product_colors_store_select" ON public.product_colors;
CREATE POLICY "product_colors_store_select" ON public.product_colors FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());
-- Escritas: só pelas funções fn_product_* (validam loja, papel e limites).

-- ------------------------------------------------------------------------------
-- 4. STORAGE: bucket público de imagens; escrita só na pasta da própria loja
-- ------------------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    VALUES ('product-images', 'product-images', TRUE, 2097152, ARRAY['image/webp', 'image/jpeg', 'image/png'])
    ON CONFLICT (id) DO UPDATE SET public = TRUE, file_size_limit = 2097152, allowed_mime_types = ARRAY['image/webp', 'image/jpeg', 'image/png'];

    DROP POLICY IF EXISTS "gef_product_images_insert" ON storage.objects;
    CREATE POLICY "gef_product_images_insert" ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'product-images' AND ((storage.foldername(name))[1] = public.get_auth_user_store_id() AND public.get_auth_user_role() IN ('ADMIN', 'GERENTE', 'ESTOQUISTA') OR public.fn_is_superadmin()));
    DROP POLICY IF EXISTS "gef_product_images_update" ON storage.objects;
    CREATE POLICY "gef_product_images_update" ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'product-images' AND ((storage.foldername(name))[1] = public.get_auth_user_store_id() AND public.get_auth_user_role() IN ('ADMIN', 'GERENTE', 'ESTOQUISTA') OR public.fn_is_superadmin()));
    DROP POLICY IF EXISTS "gef_product_images_delete" ON storage.objects;
    CREATE POLICY "gef_product_images_delete" ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'product-images' AND ((storage.foldername(name))[1] = public.get_auth_user_store_id() AND public.get_auth_user_role() IN ('ADMIN', 'GERENTE', 'ESTOQUISTA') OR public.fn_is_superadmin()));
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Storage não configurado automaticamente (%). Crie o bucket público product-images no painel do Supabase e volte a executar este bloco.', SQLERRM;
END $$;

-- ------------------------------------------------------------------------------
-- 5. ENCOMENDAS ONLINE (encomenda criada != venda confirmada != pagamento recebido)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.web_orders (
    id TEXT PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    customer_name TEXT NOT NULL,
    phone TEXT NOT NULL,
    email TEXT,
    address TEXT,
    notes TEXT,
    status TEXT NOT NULL DEFAULT 'PENDENTE' CHECK (status IN ('PENDENTE', 'CONFIRMADA', 'EM_PREPARACAO', 'ENTREGUE', 'CANCELADA')),
    payment_status TEXT NOT NULL DEFAULT 'NAO_PAGO' CHECK (payment_status IN ('NAO_PAGO', 'COMPROVATIVO_ENVIADO', 'PAGO')),
    total NUMERIC(12, 2) NOT NULL DEFAULT 0,
    sale_id TEXT REFERENCES public.sales(id) ON DELETE SET NULL,
    idempotency_key TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE (store_id, idempotency_key)
);
CREATE TABLE IF NOT EXISTS public.web_order_items (
    id BIGSERIAL PRIMARY KEY,
    order_id TEXT NOT NULL REFERENCES public.web_orders(id) ON DELETE CASCADE,
    store_id TEXT NOT NULL,
    product_id TEXT REFERENCES public.products(id) ON DELETE SET NULL,
    product_name TEXT NOT NULL,          -- snapshots: o histórico não muda se o catálogo mudar
    product_code TEXT,
    unit TEXT,
    color_id UUID,
    color_name TEXT,
    color_hex TEXT,
    quantity NUMERIC(12, 2) NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12, 2) NOT NULL,
    base_price NUMERIC(12, 2) NOT NULL,
    promo_applied BOOLEAN NOT NULL DEFAULT FALSE,
    line_total NUMERIC(12, 2) NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_web_orders_store ON public.web_orders(store_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_web_order_items_order ON public.web_order_items(order_id);
ALTER TABLE public.web_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.web_order_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "web_orders_store_select" ON public.web_orders;
CREATE POLICY "web_orders_store_select" ON public.web_orders FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());
DROP POLICY IF EXISTS "web_order_items_store_select" ON public.web_order_items;
CREATE POLICY "web_order_items_store_select" ON public.web_order_items FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());

-- Cotações online entram no mecanismo existente (public.quotes)
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'LOJA';
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_quotes_idem ON public.quotes(store_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

-- ------------------------------------------------------------------------------
-- 6. RATE LIMITING NO SERVIDOR
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.api_rate_limits (
    key TEXT NOT NULL, window_start TIMESTAMP WITH TIME ZONE NOT NULL, hits INT NOT NULL DEFAULT 0,
    PRIMARY KEY (key, window_start)
);
ALTER TABLE public.api_rate_limits ENABLE ROW LEVEL SECURITY; -- sem políticas: ninguém lê/escreve directamente

CREATE OR REPLACE FUNCTION public.fn_client_ip() RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(TRIM(split_part(COALESCE((NULLIF(current_setting('request.headers', TRUE), ''))::JSON ->> 'x-forwarded-for', ''), ',', 1)), ''), 'unknown');
$$;

CREATE OR REPLACE FUNCTION public.fn_rate_limit(p_key TEXT, p_max INT, p_window_seconds INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_bucket TIMESTAMP WITH TIME ZONE; v_hits INT;
BEGIN
    v_bucket := to_timestamp(floor(extract(epoch FROM NOW()) / p_window_seconds) * p_window_seconds);
    INSERT INTO public.api_rate_limits(key, window_start, hits) VALUES (p_key, v_bucket, 1)
    ON CONFLICT (key, window_start) DO UPDATE SET hits = public.api_rate_limits.hits + 1
    RETURNING hits INTO v_hits;
    IF v_hits > p_max THEN
        RAISE EXCEPTION 'Demasiados pedidos. Aguarde um momento e tente novamente.' USING ERRCODE = 'P0001';
    END IF;
    IF random() < 0.01 THEN DELETE FROM public.api_rate_limits WHERE window_start < NOW() - INTERVAL '1 day'; END IF;
END; $$;
REVOKE ALL ON FUNCTION public.fn_rate_limit(TEXT, INT, INT) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------------------
-- 7. RPCs PÚBLICAS
-- ------------------------------------------------------------------------------
-- A loja pública só responde se a loja estiver activa no sistema E a loja virtual estiver activada (estados separados).
CREATE OR REPLACE FUNCTION public.fn_vstore_resolve(p_slug TEXT) RETURNS public.stores
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE;
BEGIN
    SELECT * INTO s FROM public.stores WHERE slug = lower(TRIM(COALESCE(p_slug, '')));
    IF s.id IS NULL OR NOT s.vstore_enabled OR COALESCE(s.acesso_ativo, TRUE) = FALSE THEN
        RAISE EXCEPTION 'LOJA_INDISPONIVEL' USING ERRCODE = 'P0002';
    END IF;
    RETURN s;
END; $$;
REVOKE ALL ON FUNCTION public.fn_vstore_resolve(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_public_store(p_slug TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
        'categories', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', c.category, 'count', c.n) ORDER BY c.category)
                                  FROM (SELECT category, COUNT(*) AS n FROM public.products WHERE store_id = s.id AND published AND COALESCE(active, TRUE) GROUP BY category) c
                                 WHERE NOT (COALESCE(s.vstore_config -> 'categories_hidden', '[]'::JSONB) ? c.category)), '[]'::JSONB));
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_store(TEXT) TO anon, authenticated;

-- Catálogo paginado por cursor (keyset). Limite máximo 24 por pedido.
CREATE OR REPLACE FUNCTION public.fn_public_products(
    p_slug TEXT, p_q TEXT DEFAULT NULL, p_category TEXT DEFAULT NULL, p_sort TEXT DEFAULT 'recent',
    p_only_promo BOOLEAN DEFAULT FALSE, p_featured BOOLEAN DEFAULT FALSE, p_cursor TEXT DEFAULT NULL, p_limit INT DEFAULT 24)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
        v_pat := '%' || replace(replace(replace(LEFT(TRIM(p_q), 60), '\', '\\'), '%', '\%'), '_', '\_') || '%';
        v_where := v_where || format(' AND (p.name ILIKE %1$L OR p.brand ILIKE %1$L OR p.model ILIKE %1$L OR p.code ILIKE %1$L OR p.category ILIKE %1$L)', v_pat);
    END IF;
    IF NULLIF(TRIM(COALESCE(p_category, '')), '') IS NOT NULL THEN v_where := v_where || format(' AND p.category = %L', p_category); END IF;
    IF p_only_promo THEN v_where := v_where || ' AND public.fn_effective_price(p) < p.sale_price'; END IF;
    IF p_featured THEN v_where := v_where || ' AND p.featured'; END IF;
    IF NULLIF(COALESCE(p_cursor, ''), '') IS NOT NULL THEN
        BEGIN v_cur := p_cursor::JSONB; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Cursor inválido.'; END;
        v_where := v_where || format(' AND (%s, p.id) %s (%L::%s, %L)', v_expr, v_op, v_cur ->> 'k', v_type, v_cur ->> 'id');
    END IF;

    v_sql := format($q$
        SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.rn), '[]'::JSONB) FROM (
            SELECT row_number() OVER (ORDER BY %1$s %2$s, p.id %2$s) AS rn, p.id, p.name, p.category, p.brand, p.unit, p.has_colors,
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
GRANT EXECUTE ON FUNCTION public.fn_public_products(TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, INT) TO anon, authenticated;

-- Página individual (o identificador é o id do produto: estável mesmo que nome/preço mudem)
CREATE OR REPLACE FUNCTION public.fn_public_product(p_slug TEXT, p_product_id TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
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
    RETURN jsonb_build_object('ok', TRUE, 'id', p.id, 'name', p.name, 'code', p.code, 'category', p.category, 'brand', p.brand, 'model', p.model,
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

-- Encomenda: o servidor revalida produtos, preço aplicável (promoção válida AGORA), cor e stock por cor, de forma atómica e idempotente.
CREATE OR REPLACE FUNCTION public.fn_public_create_order(p_slug TEXT, p_customer JSONB, p_items JSONB, p_idem TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    s public.stores%ROWTYPE; v_name TEXT; v_phone TEXT; v_id TEXT; v_code TEXT; it JSONB; pr public.products%ROWTYPE; col public.product_colors%ROWTYPE;
    v_qty NUMERIC; v_price NUMERIC; v_total NUMERIC := 0; v_ex RECORD;
BEGIN
    s := public.fn_vstore_resolve(p_slug);
    PERFORM public.fn_rate_limit('order:' || public.fn_client_ip() || ':' || s.id, 6, 600);
    IF p_idem IS NULL OR LENGTH(p_idem) < 8 OR LENGTH(p_idem) > 80 THEN RAISE EXCEPTION 'Pedido inválido (chave em falta).'; END IF;
    SELECT id, code, total INTO v_ex FROM public.web_orders WHERE store_id = s.id AND idempotency_key = p_idem;
    IF v_ex.id IS NOT NULL THEN RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'code', v_ex.code, 'total', v_ex.total); END IF;

    v_name := LEFT(TRIM(COALESCE(p_customer ->> 'name', '')), 120);
    v_phone := LEFT(TRIM(COALESCE(p_customer ->> 'phone', '')), 30);
    IF v_name = '' THEN RAISE EXCEPTION 'Indique o seu nome.'; END IF;
    IF LENGTH(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 THEN RAISE EXCEPTION 'Indique um telefone válido.'; END IF;
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'O carrinho está vazio.'; END IF;
    IF jsonb_array_length(p_items) > 30 THEN RAISE EXCEPTION 'Máximo de 30 linhas por encomenda.'; END IF;

    v_id := 'wo-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_code := 'ENC-' || UPPER(SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 8));
    BEGIN
        INSERT INTO public.web_orders (id, code, store_id, customer_name, phone, email, address, notes, idempotency_key)
        VALUES (v_id, v_code, s.id, v_name, v_phone, NULLIF(LEFT(TRIM(COALESCE(p_customer ->> 'email', '')), 120), ''),
                NULLIF(LEFT(TRIM(COALESCE(p_customer ->> 'address', '')), 300), ''), NULLIF(LEFT(TRIM(COALESCE(p_customer ->> 'notes', '')), 500), ''), p_idem);
    EXCEPTION WHEN unique_violation THEN
        SELECT id, code, total INTO v_ex FROM public.web_orders WHERE store_id = s.id AND idempotency_key = p_idem;
        RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'code', v_ex.code, 'total', v_ex.total);
    END;

    FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        SELECT * INTO pr FROM public.products WHERE id = it ->> 'product_id' AND store_id = s.id AND published AND COALESCE(active, TRUE);
        IF pr.id IS NULL THEN RAISE EXCEPTION 'Um dos produtos já não está disponível. Actualize o carrinho.'; END IF;
        BEGIN v_qty := (it ->> 'quantity')::NUMERIC; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Quantidade inválida.'; END;
        IF v_qty IS NULL OR v_qty <= 0 OR v_qty > 9999 THEN RAISE EXCEPTION 'Quantidade inválida para %.', pr.name; END IF;
        IF NOT COALESCE(pr.is_fractional, FALSE) AND v_qty <> trunc(v_qty) THEN RAISE EXCEPTION 'A quantidade de % deve ser inteira.', pr.name; END IF;

        col := NULL;
        IF pr.has_colors THEN
            IF NULLIF(it ->> 'color_id', '') IS NULL THEN
                IF pr.color_required THEN RAISE EXCEPTION 'Seleccione a cor de %.', pr.name; END IF;
            ELSE
                SELECT * INTO col FROM public.product_colors WHERE id = (it ->> 'color_id')::UUID AND product_id = pr.id FOR UPDATE;
                IF col.id IS NULL THEN RAISE EXCEPTION 'A cor escolhida não existe para %.', pr.name; END IF;
                IF NOT col.available THEN RAISE EXCEPTION 'A cor % de % não está disponível.', col.name, pr.name; END IF;
                IF col.stock_qty IS NOT NULL THEN
                    IF col.stock_qty < v_qty THEN RAISE EXCEPTION 'Stock insuficiente na cor % de % (disponível: %).', col.name, pr.name, col.stock_qty; END IF;
                    UPDATE public.product_colors SET stock_qty = stock_qty - v_qty WHERE id = col.id;
                END IF;
            END IF;
        ELSIF COALESCE(pr.current_stock, 0) <= 0 THEN
            RAISE EXCEPTION '% está indisponível.', pr.name;
        END IF;

        v_price := public.fn_effective_price(pr);
        INSERT INTO public.web_order_items (order_id, store_id, product_id, product_name, product_code, unit, color_id, color_name, color_hex,
                                            quantity, unit_price, base_price, promo_applied, line_total)
        VALUES (v_id, s.id, pr.id, pr.name, pr.code, COALESCE(pr.sale_unit, pr.unit), col.id, col.name, col.hex,
                v_qty, v_price, pr.sale_price, v_price < pr.sale_price, ROUND(v_price * v_qty, 2));
        v_total := v_total + ROUND(v_price * v_qty, 2);
    END LOOP;

    UPDATE public.web_orders SET total = v_total WHERE id = v_id;
    RETURN jsonb_build_object('success', TRUE, 'duplicate', FALSE, 'code', v_code, 'total', v_total);
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_create_order(TEXT, JSONB, JSONB, TEXT) TO anon, authenticated;

-- Pedido de cotação online -> public.quotes (mecanismo existente; validade 15 dias; nada é apagado ao expirar)
CREATE OR REPLACE FUNCTION public.fn_public_request_quote(p_slug TEXT, p_customer JSONB, p_items JSONB, p_idem TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE; v_name TEXT; v_phone TEXT; v_id TEXT; v_num TEXT; it JSONB; pr public.products%ROWTYPE; v_qty NUMERIC; v_price NUMERIC;
        v_items JSONB := '[]'::JSONB; v_total NUMERIC := 0; v_ex RECORD; v_color TEXT;
BEGIN
    s := public.fn_vstore_resolve(p_slug);
    PERFORM public.fn_rate_limit('quote:' || public.fn_client_ip() || ':' || s.id, 6, 600);
    IF p_idem IS NULL OR LENGTH(p_idem) < 8 OR LENGTH(p_idem) > 80 THEN RAISE EXCEPTION 'Pedido inválido (chave em falta).'; END IF;
    SELECT id, quote_number, total INTO v_ex FROM public.quotes WHERE store_id = s.id AND idempotency_key = p_idem;
    IF v_ex.id IS NOT NULL THEN RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'code', v_ex.quote_number); END IF;

    v_name := LEFT(TRIM(COALESCE(p_customer ->> 'name', '')), 120);
    v_phone := LEFT(TRIM(COALESCE(p_customer ->> 'phone', '')), 30);
    IF v_name = '' THEN RAISE EXCEPTION 'Indique o seu nome.'; END IF;
    IF LENGTH(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 7 THEN RAISE EXCEPTION 'Indique um telefone válido.'; END IF;
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 OR jsonb_array_length(p_items) > 30 THEN RAISE EXCEPTION 'Indique entre 1 e 30 produtos.'; END IF;

    FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        SELECT * INTO pr FROM public.products WHERE id = it ->> 'product_id' AND store_id = s.id AND published AND COALESCE(active, TRUE);
        IF pr.id IS NULL THEN RAISE EXCEPTION 'Um dos produtos já não está disponível.'; END IF;
        BEGIN v_qty := (it ->> 'quantity')::NUMERIC; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'Quantidade inválida.'; END;
        IF v_qty IS NULL OR v_qty <= 0 OR v_qty > 9999 THEN RAISE EXCEPTION 'Quantidade inválida para %.', pr.name; END IF;
        v_color := NULL;
        IF NULLIF(it ->> 'color_id', '') IS NOT NULL THEN
            SELECT name INTO v_color FROM public.product_colors WHERE id = (it ->> 'color_id')::UUID AND product_id = pr.id;
        END IF;
        v_price := public.fn_effective_price(pr);
        v_items := v_items || jsonb_build_array(jsonb_build_object('productId', pr.id, 'name', pr.name, 'unit', COALESCE(pr.sale_unit, pr.unit),
                          'unitPrice', v_price, 'quantity', v_qty, 'colorName', v_color));
        v_total := v_total + ROUND(v_price * v_qty, 2);
    END LOOP;

    v_id := 'q-' || SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 16);
    v_num := 'COT-' || UPPER(SUBSTR(REPLACE(gen_random_uuid()::TEXT, '-', ''), 1, 8));
    BEGIN
        INSERT INTO public.quotes (id, store_id, quote_number, customer_name, phone, items, total, valid_until, status, source, notes, idempotency_key)
        VALUES (v_id, s.id, v_num, v_name, v_phone, v_items, v_total, CURRENT_DATE + 15, 'PENDENTE', 'LOJA_ONLINE',
                NULLIF(LEFT(TRIM(COALESCE(p_customer ->> 'notes', '')), 500), ''), p_idem);
    EXCEPTION WHEN unique_violation THEN
        SELECT quote_number INTO v_num FROM public.quotes WHERE store_id = s.id AND idempotency_key = p_idem;
        RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'code', v_num);
    END;
    RETURN jsonb_build_object('success', TRUE, 'duplicate', FALSE, 'code', v_num, 'total', v_total);
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_request_quote(TEXT, JSONB, JSONB, TEXT) TO anon, authenticated;

-- ------------------------------------------------------------------------------
-- 8. RPCs DA LOJA (utilizadores autorizados da própria loja)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_catalog_store_id(p_roles TEXT[] DEFAULT ARRAY['ADMIN', 'GERENTE', 'ESTOQUISTA']) RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_role TEXT := public.get_auth_user_role(); v_store TEXT := public.get_auth_user_store_id();
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;
    IF v_store IS NULL OR v_role IS NULL OR NOT (v_role = ANY (p_roles)) THEN RAISE EXCEPTION 'Sem permissão para esta operação.'; END IF;
    RETURN v_store;
END; $$;
REVOKE ALL ON FUNCTION public.fn_catalog_store_id(TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_catalog_store_id(TEXT[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_vstore_my_info() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE;
BEGIN
    SELECT * INTO s FROM public.stores WHERE id = public.get_auth_user_store_id();
    IF s.id IS NULL THEN RAISE EXCEPTION 'Loja não encontrada.'; END IF;
    RETURN jsonb_build_object('store_id', s.id, 'slug', s.slug, 'enabled', s.vstore_enabled, 'store_active', COALESCE(s.acesso_ativo, TRUE),
        'theme', s.vstore_theme, 'config', s.vstore_config, 'max_images', public.fn_max_product_images(),
        'themes', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) ORDER BY t.sort_order) FROM public.vstore_themes t WHERE t.enabled), '[]'::JSONB));
END; $$;
REVOKE ALL ON FUNCTION public.fn_vstore_my_info() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_vstore_my_info() TO authenticated;

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
        'sections', CASE WHEN jsonb_array_length(v_sections) > 0 THEN v_sections END,
        'categories_hidden', CASE WHEN jsonb_typeof(p_config -> 'categories_hidden') = 'array' THEN (SELECT jsonb_agg(LEFT(x, 60)) FROM (SELECT x FROM jsonb_array_elements_text(p_config -> 'categories_hidden') x LIMIT 50) q) END));
    UPDATE public.stores SET vstore_theme = p_theme, vstore_config = v_cfg, updated_at = NOW() WHERE id = v_store;
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_vstore_save_config(TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_vstore_save_config(TEXT, JSONB) TO authenticated;

-- Dados "loja virtual" de um produto (para o ecrã de edição)
CREATE OR REPLACE FUNCTION public.fn_product_shop_get(p_product_id TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(); p public.products%ROWTYPE;
BEGIN
    SELECT * INTO p FROM public.products WHERE id = p_product_id AND store_id = v_store;
    IF p.id IS NULL THEN RAISE EXCEPTION 'Produto não encontrado.'; END IF;
    RETURN jsonb_build_object('id', p.id, 'name', p.name, 'sale_price', p.sale_price, 'published', p.published, 'description', p.description, 'details', p.details, 'notes', p.notes,
        'brand', p.brand, 'model', p.model, 'sale_unit', p.sale_unit, 'promo_price', p.promo_price, 'promo_start', p.promo_start, 'promo_end', p.promo_end,
        'promo_active', p.promo_active, 'featured', p.featured, 'featured_order', p.featured_order, 'has_colors', p.has_colors, 'color_required', p.color_required,
        'images', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'path', i.path, 'thumb', i.thumb_path, 'main', i.is_main) ORDER BY i.is_main DESC, i.sort_order, i.created_at) FROM public.product_images i WHERE i.product_id = p.id), '[]'::JSONB),
        'colors', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'hex', c.hex, 'available', c.available, 'stock_qty', c.stock_qty, 'image_id', c.image_id) ORDER BY c.sort_order, c.name) FROM public.product_colors c WHERE c.product_id = p.id), '[]'::JSONB));
END; $$;
REVOKE ALL ON FUNCTION public.fn_product_shop_get(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_shop_get(TEXT) TO authenticated;

-- Guardar dados comerciais + cores (as cores são sincronizadas por id; encomendas antigas mantêm o seu snapshot)
CREATE OR REPLACE FUNCTION public.fn_product_shop_save(p_product_id TEXT, p_data JSONB, p_colors JSONB DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(); p public.products%ROWTYPE; c JSONB; v_ids UUID[] := ARRAY[]::UUID[]; v_id UUID; v_n INT := 0; v_promo NUMERIC; v_has BOOLEAN;
BEGIN
    SELECT * INTO p FROM public.products WHERE id = p_product_id AND store_id = v_store FOR UPDATE;
    IF p.id IS NULL THEN RAISE EXCEPTION 'Produto não encontrado.'; END IF;
    PERFORM public.fn_rate_limit('pshop:' || auth.uid()::TEXT, 120, 60);
    v_promo := NULLIF(p_data ->> 'promo_price', '')::NUMERIC;
    IF v_promo IS NOT NULL AND (v_promo < 0 OR v_promo >= p.sale_price) THEN RAISE EXCEPTION 'O preço promocional deve ser inferior ao preço de venda.'; END IF;
    IF NULLIF(p_data ->> 'promo_start', '') IS NOT NULL AND NULLIF(p_data ->> 'promo_end', '') IS NOT NULL
       AND (p_data ->> 'promo_end')::TIMESTAMPTZ < (p_data ->> 'promo_start')::TIMESTAMPTZ THEN RAISE EXCEPTION 'A promoção termina antes de começar.'; END IF;
    v_has := COALESCE((p_data ->> 'has_colors')::BOOLEAN, p.has_colors);

    UPDATE public.products SET
        published = COALESCE((p_data ->> 'published')::BOOLEAN, published),
        description = CASE WHEN p_data ? 'description' THEN NULLIF(LEFT(TRIM(p_data ->> 'description'), 4000), '') ELSE description END,
        details = CASE WHEN p_data ? 'details' THEN NULLIF(LEFT(TRIM(p_data ->> 'details'), 4000), '') ELSE details END,
        notes = CASE WHEN p_data ? 'notes' THEN NULLIF(LEFT(TRIM(p_data ->> 'notes'), 2000), '') ELSE notes END,
        brand = CASE WHEN p_data ? 'brand' THEN NULLIF(LEFT(TRIM(p_data ->> 'brand'), 80), '') ELSE brand END,
        model = CASE WHEN p_data ? 'model' THEN NULLIF(LEFT(TRIM(p_data ->> 'model'), 80), '') ELSE model END,
        sale_unit = CASE WHEN p_data ? 'sale_unit' THEN NULLIF(LEFT(TRIM(p_data ->> 'sale_unit'), 30), '') ELSE sale_unit END,
        promo_price = CASE WHEN p_data ? 'promo_price' THEN v_promo ELSE promo_price END,
        promo_start = CASE WHEN p_data ? 'promo_start' THEN NULLIF(p_data ->> 'promo_start', '')::TIMESTAMPTZ ELSE promo_start END,
        promo_end = CASE WHEN p_data ? 'promo_end' THEN NULLIF(p_data ->> 'promo_end', '')::TIMESTAMPTZ ELSE promo_end END,
        promo_active = COALESCE((p_data ->> 'promo_active')::BOOLEAN, promo_active),
        featured = COALESCE((p_data ->> 'featured')::BOOLEAN, featured),
        featured_order = CASE WHEN p_data ? 'featured_order' THEN NULLIF(p_data ->> 'featured_order', '')::INT ELSE featured_order END,
        has_colors = v_has,
        color_required = COALESCE((p_data ->> 'color_required')::BOOLEAN, color_required),
        updated_at = NOW()
     WHERE id = p.id;

    IF p_colors IS NOT NULL AND jsonb_typeof(p_colors) = 'array' THEN
        IF jsonb_array_length(p_colors) > 30 THEN RAISE EXCEPTION 'Máximo de 30 cores por produto.'; END IF;
        FOR c IN SELECT * FROM jsonb_array_elements(p_colors) LOOP
            IF NULLIF(TRIM(COALESCE(c ->> 'name', '')), '') IS NULL THEN RAISE EXCEPTION 'Cada cor precisa de um nome.'; END IF;
            v_n := v_n + 1;
            IF NULLIF(c ->> 'id', '') IS NOT NULL AND EXISTS (SELECT 1 FROM public.product_colors WHERE id = (c ->> 'id')::UUID AND product_id = p.id) THEN
                v_id := (c ->> 'id')::UUID;
                UPDATE public.product_colors SET name = LEFT(TRIM(c ->> 'name'), 40), hex = NULLIF(c ->> 'hex', ''), available = COALESCE((c ->> 'available')::BOOLEAN, TRUE),
                       stock_qty = NULLIF(c ->> 'stock_qty', '')::NUMERIC, sort_order = v_n,
                       image_id = (SELECT i.id FROM public.product_images i WHERE i.id = NULLIF(c ->> 'image_id', '')::UUID AND i.product_id = p.id)
                 WHERE id = v_id;
            ELSE
                INSERT INTO public.product_colors (product_id, store_id, name, hex, available, stock_qty, sort_order, image_id)
                VALUES (p.id, v_store, LEFT(TRIM(c ->> 'name'), 40), NULLIF(c ->> 'hex', ''), COALESCE((c ->> 'available')::BOOLEAN, TRUE), NULLIF(c ->> 'stock_qty', '')::NUMERIC, v_n,
                        (SELECT i.id FROM public.product_images i WHERE i.id = NULLIF(c ->> 'image_id', '')::UUID AND i.product_id = p.id))
                RETURNING id INTO v_id;
            END IF;
            v_ids := v_ids || v_id;
        END LOOP;
        DELETE FROM public.product_colors WHERE product_id = p.id AND NOT (id = ANY (v_ids));
    END IF;
    RETURN jsonb_build_object('success', TRUE);
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'Nomes de cor repetidos neste produto.';
END; $$;
REVOKE ALL ON FUNCTION public.fn_product_shop_save(TEXT, JSONB, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_shop_save(TEXT, JSONB, JSONB) TO authenticated;

-- Fotografias: o ficheiro já foi enviado para o Storage; aqui regista-se (valida pasta, limite e dono)
CREATE OR REPLACE FUNCTION public.fn_product_image_add(p_product_id TEXT, p_path TEXT, p_thumb TEXT, p_size INT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(); p public.products%ROWTYPE; v_id UUID; v_n INT;
BEGIN
    PERFORM public.fn_rate_limit('pimg:' || auth.uid()::TEXT, 60, 60);
    SELECT * INTO p FROM public.products WHERE id = p_product_id AND store_id = v_store FOR UPDATE;
    IF p.id IS NULL THEN RAISE EXCEPTION 'Produto não encontrado.'; END IF;
    IF p_path IS NULL OR p_path NOT LIKE v_store || '/' || p.id || '/%' OR (p_thumb IS NOT NULL AND p_thumb NOT LIKE v_store || '/' || p.id || '/%') THEN
        RAISE EXCEPTION 'Caminho de ficheiro inválido.';
    END IF;
    SELECT COUNT(*) INTO v_n FROM public.product_images WHERE product_id = p.id;
    IF v_n >= public.fn_max_product_images() THEN RAISE EXCEPTION 'Cada produto aceita no máximo % fotografias.', public.fn_max_product_images(); END IF;
    INSERT INTO public.product_images (product_id, store_id, path, thumb_path, size_bytes, sort_order, is_main)
    VALUES (p.id, v_store, p_path, p_thumb, p_size, COALESCE((SELECT MAX(sort_order) + 1 FROM public.product_images WHERE product_id = p.id), 0), v_n = 0)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('success', TRUE, 'id', v_id, 'is_main', v_n = 0);
END; $$;
REVOKE ALL ON FUNCTION public.fn_product_image_add(TEXT, TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_image_add(TEXT, TEXT, TEXT, INT) TO authenticated;

-- Substituir mantém o mesmo registo (id, posição, principal); devolve os caminhos antigos para o cliente apagar do Storage
CREATE OR REPLACE FUNCTION public.fn_product_image_replace(p_image_id UUID, p_path TEXT, p_thumb TEXT, p_size INT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(); i public.product_images%ROWTYPE;
BEGIN
    SELECT * INTO i FROM public.product_images WHERE id = p_image_id AND store_id = v_store FOR UPDATE;
    IF i.id IS NULL THEN RAISE EXCEPTION 'Fotografia não encontrada.'; END IF;
    IF p_path IS NULL OR p_path NOT LIKE v_store || '/' || i.product_id || '/%' OR (p_thumb IS NOT NULL AND p_thumb NOT LIKE v_store || '/' || i.product_id || '/%') THEN RAISE EXCEPTION 'Caminho de ficheiro inválido.'; END IF;
    UPDATE public.product_images SET path = p_path, thumb_path = p_thumb, size_bytes = p_size WHERE id = i.id;
    RETURN jsonb_build_object('success', TRUE, 'old_path', i.path, 'old_thumb', i.thumb_path);
END; $$;
REVOKE ALL ON FUNCTION public.fn_product_image_replace(UUID, TEXT, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_image_replace(UUID, TEXT, TEXT, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_product_image_delete(p_image_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(); i public.product_images%ROWTYPE;
BEGIN
    SELECT * INTO i FROM public.product_images WHERE id = p_image_id AND store_id = v_store FOR UPDATE;
    IF i.id IS NULL THEN RAISE EXCEPTION 'Fotografia não encontrada.'; END IF;
    DELETE FROM public.product_images WHERE id = i.id;
    IF i.is_main THEN
        UPDATE public.product_images SET is_main = TRUE WHERE id = (SELECT id FROM public.product_images WHERE product_id = i.product_id ORDER BY sort_order, created_at LIMIT 1);
    END IF;
    RETURN jsonb_build_object('success', TRUE, 'old_path', i.path, 'old_thumb', i.thumb_path);
END; $$;
REVOKE ALL ON FUNCTION public.fn_product_image_delete(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_image_delete(UUID) TO authenticated;

-- Principal + ordem numa só chamada: p_ids = ids pela nova ordem; o primeiro passa a ser a principal.
CREATE OR REPLACE FUNCTION public.fn_product_image_order(p_product_id TEXT, p_ids UUID[], p_main UUID DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(); v_main UUID; n INT := 0; v_id UUID;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id AND store_id = v_store) THEN RAISE EXCEPTION 'Produto não encontrado.'; END IF;
    v_main := COALESCE(p_main, p_ids[1]);
    UPDATE public.product_images SET is_main = FALSE WHERE product_id = p_product_id AND is_main;
    FOREACH v_id IN ARRAY COALESCE(p_ids, ARRAY[]::UUID[]) LOOP
        UPDATE public.product_images SET sort_order = n WHERE id = v_id AND product_id = p_product_id;
        n := n + 1;
    END LOOP;
    UPDATE public.product_images SET is_main = TRUE WHERE id = v_main AND product_id = p_product_id;
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_product_image_order(TEXT, UUID[], UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_product_image_order(TEXT, UUID[], UUID) TO authenticated;

-- Encomendas online da loja (paginação por cursor)
CREATE OR REPLACE FUNCTION public.fn_store_orders_list(p_status TEXT DEFAULT NULL, p_q TEXT DEFAULT NULL, p_before TIMESTAMPTZ DEFAULT NULL, p_before_id TEXT DEFAULT NULL, p_limit INT DEFAULT 20) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE', 'ESTOQUISTA', 'CASHIER']); v_lim INT := LEAST(GREATEST(COALESCE(p_limit, 20), 1), 50); v_rows JSONB; v_next JSONB; v_pat TEXT;
BEGIN
    v_pat := CASE WHEN NULLIF(TRIM(COALESCE(p_q, '')), '') IS NULL THEN NULL ELSE '%' || replace(replace(replace(LEFT(TRIM(p_q), 60), '\', '\\'), '%', '\%'), '_', '\_') || '%' END;
    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC, x.id DESC), '[]'::JSONB) INTO v_rows FROM (
        SELECT o.id, o.code, o.customer_name, o.phone, o.status, o.payment_status, o.total, o.created_at,
               (SELECT COUNT(*) FROM public.web_order_items i WHERE i.order_id = o.id) AS lines
          FROM public.web_orders o
         WHERE o.store_id = v_store AND (p_status IS NULL OR o.status = p_status)
           AND (v_pat IS NULL OR o.code ILIKE v_pat OR o.customer_name ILIKE v_pat OR o.phone ILIKE v_pat)
           AND (p_before IS NULL OR (o.created_at, o.id) < (p_before, COALESCE(p_before_id, 'zzzz')))
         ORDER BY o.created_at DESC, o.id DESC LIMIT v_lim + 1) x;
    IF jsonb_array_length(v_rows) > v_lim THEN
        v_next := jsonb_build_object('before', v_rows -> (v_lim - 1) ->> 'created_at', 'before_id', v_rows -> (v_lim - 1) ->> 'id');
        SELECT COALESCE(jsonb_agg(e), '[]'::JSONB) INTO v_rows FROM (SELECT e FROM jsonb_array_elements(v_rows) WITH ORDINALITY t(e, n) WHERE n <= v_lim ORDER BY n) z;
    END IF;
    RETURN jsonb_build_object('items', v_rows, 'next', v_next);
END; $$;
REVOKE ALL ON FUNCTION public.fn_store_orders_list(TEXT, TEXT, TIMESTAMPTZ, TEXT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_orders_list(TEXT, TEXT, TIMESTAMPTZ, TEXT, INT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_store_order_get(p_order_id TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE', 'ESTOQUISTA', 'CASHIER']); o public.web_orders%ROWTYPE;
BEGIN
    SELECT * INTO o FROM public.web_orders WHERE id = p_order_id AND store_id = v_store;
    IF o.id IS NULL THEN RAISE EXCEPTION 'Encomenda não encontrada.'; END IF;
    RETURN to_jsonb(o) || jsonb_build_object('items', COALESCE((SELECT jsonb_agg(jsonb_build_object('product_id', i.product_id, 'name', i.product_name, 'code', i.product_code, 'unit', i.unit,
              'color_name', i.color_name, 'color_hex', i.color_hex, 'quantity', i.quantity, 'unit_price', i.unit_price, 'base_price', i.base_price, 'promo_applied', i.promo_applied, 'line_total', i.line_total) ORDER BY i.id)
              FROM public.web_order_items i WHERE i.order_id = o.id), '[]'::JSONB));
END; $$;
REVOKE ALL ON FUNCTION public.fn_store_order_get(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_order_get(TEXT) TO authenticated;

-- Estado da encomenda / pagamento: só utilizadores autorizados; cancelar repõe o stock por cor (uma só vez)
CREATE OR REPLACE FUNCTION public.fn_store_order_set_status(p_order_id TEXT, p_status TEXT, p_payment_status TEXT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']); o public.web_orders%ROWTYPE; i RECORD;
BEGIN
    SELECT * INTO o FROM public.web_orders WHERE id = p_order_id AND store_id = v_store FOR UPDATE;
    IF o.id IS NULL THEN RAISE EXCEPTION 'Encomenda não encontrada.'; END IF;
    IF p_status IS NOT NULL AND p_status NOT IN ('PENDENTE', 'CONFIRMADA', 'EM_PREPARACAO', 'ENTREGUE', 'CANCELADA') THEN RAISE EXCEPTION 'Estado inválido.'; END IF;
    IF p_payment_status IS NOT NULL AND p_payment_status NOT IN ('NAO_PAGO', 'COMPROVATIVO_ENVIADO', 'PAGO') THEN RAISE EXCEPTION 'Estado de pagamento inválido.'; END IF;
    IF o.status = 'CANCELADA' AND p_status IS NOT NULL AND p_status <> 'CANCELADA' THEN RAISE EXCEPTION 'Uma encomenda cancelada não pode ser reaberta.'; END IF;
    IF p_status = 'CANCELADA' AND o.status <> 'CANCELADA' THEN
        FOR i IN SELECT color_id, quantity FROM public.web_order_items WHERE order_id = o.id AND color_id IS NOT NULL LOOP
            UPDATE public.product_colors SET stock_qty = stock_qty + i.quantity WHERE id = i.color_id AND stock_qty IS NOT NULL;
        END LOOP;
    END IF;
    UPDATE public.web_orders SET status = COALESCE(p_status, status), payment_status = COALESCE(p_payment_status, payment_status), updated_at = NOW() WHERE id = o.id;
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_store_order_set_status(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_order_set_status(TEXT, TEXT, TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 9. SUPER ADMIN
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_admin_set_vstore(p_store_id TEXT, p_enabled BOOLEAN, p_slug TEXT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE; v_slug TEXT;
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    SELECT * INTO s FROM public.stores WHERE id = p_store_id FOR UPDATE;
    IF s.id IS NULL THEN RAISE EXCEPTION 'Loja não encontrada.'; END IF;
    v_slug := s.slug;
    IF NULLIF(TRIM(COALESCE(p_slug, '')), '') IS NOT NULL THEN
        v_slug := public.fn_make_slug(p_slug);
        IF EXISTS (SELECT 1 FROM public.stores WHERE slug = v_slug AND id <> s.id) THEN RAISE EXCEPTION 'Esse endereço já está em uso.'; END IF;
    END IF;
    UPDATE public.stores SET vstore_enabled = COALESCE(p_enabled, vstore_enabled), slug = v_slug, updated_at = NOW() WHERE id = s.id;
    PERFORM public.fn_amb_audit(CASE WHEN p_enabled THEN 'VSTORE_ENABLED' ELSE 'VSTORE_DISABLED' END, NULL, s.id, NULL, jsonb_build_object('slug', v_slug, 'old_slug', s.slug));
    RETURN jsonb_build_object('success', TRUE, 'slug', v_slug);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_set_vstore(TEXT, BOOLEAN, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_set_vstore(TEXT, BOOLEAN, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_set_theme_enabled(p_theme TEXT, p_enabled BOOLEAN) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    UPDATE public.vstore_themes SET enabled = COALESCE(p_enabled, enabled) WHERE id = p_theme;
    IF NOT FOUND THEN RAISE EXCEPTION 'Tema não encontrado.'; END IF;
    RETURN jsonb_build_object('success', TRUE);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_set_theme_enabled(TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_set_theme_enabled(TEXT, BOOLEAN) TO authenticated;

-- Visão global numa só consulta agregada (sem N+1): produtos, publicados, encomendas e vendas dos últimos 30 dias, por loja
CREATE OR REPLACE FUNCTION public.fn_admin_stores_overview() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT public.fn_is_superadmin() THEN RAISE EXCEPTION 'Acesso reservado ao Super Administrador.'; END IF;
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('store_id', s.id, 'slug', s.slug, 'vstore_enabled', s.vstore_enabled, 'store_active', COALESCE(s.acesso_ativo, TRUE),
              'products', COALESCE(p.n, 0), 'published', COALESCE(p.pub, 0), 'web_orders_30d', COALESCE(o.n, 0), 'sales_30d', COALESCE(v.n, 0), 'sales_30d_total', COALESCE(v.t, 0),
              'last_sale', v.last_at, 'users', COALESCE(u.n, 0), 'monthly_fee', s.valor_mensalidade))
        FROM public.stores s
        LEFT JOIN (SELECT store_id, COUNT(*) n, COUNT(*) FILTER (WHERE published) pub FROM public.products GROUP BY store_id) p ON p.store_id = s.id
        LEFT JOIN (SELECT store_id, COUNT(*) n FROM public.web_orders WHERE created_at >= NOW() - INTERVAL '30 days' GROUP BY store_id) o ON o.store_id = s.id
        LEFT JOIN (SELECT store_id, COUNT(*) n, SUM(total_net) t, MAX(created_at) last_at FROM public.sales WHERE created_at >= NOW() - INTERVAL '30 days' GROUP BY store_id) v ON v.store_id = s.id
        LEFT JOIN (SELECT store_id, COUNT(*) n FROM public.profiles WHERE store_id IS NOT NULL GROUP BY store_id) u ON u.store_id = s.id), '[]'::JSONB);
END; $$;
REVOKE ALL ON FUNCTION public.fn_admin_stores_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_stores_overview() TO authenticated;

-- ------------------------------------------------------------------------------
-- 10. ÍNDICES DE DESEMPENHO
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_products_store_published ON public.products(store_id, published, created_at DESC) WHERE published;
CREATE INDEX IF NOT EXISTS idx_products_store_name ON public.products(store_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_products_store_featured ON public.products(store_id, featured_order) WHERE featured;
CREATE INDEX IF NOT EXISTS idx_sales_store_created ON public.sales(store_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON public.sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_quotes_store_created ON public.quotes(store_id, created_at DESC);
DO $$ BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE INDEX IF NOT EXISTS idx_products_name_trgm ON public.products USING gin (name gin_trgm_ops);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pg_trgm indisponível: a pesquisa continua a funcionar, sem índice de texto.';
END $$;

-- ------------------------------------------------------------------------------
-- 11. DESEMPENHO DO PAINEL FINANCEIRO: "impressão digital" barata das vendas do mês.
--     O painel só volta a descarregar vendas + itens quando esta impressão muda (antes: tudo, de 15 em 15 s).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_sales_fingerprint(p_store_id TEXT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := COALESCE(NULLIF(p_store_id, ''), public.get_auth_user_store_id()); v_super BOOLEAN := public.fn_is_superadmin(); r RECORD;
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão não autenticada.'; END IF;
    IF NOT v_super AND v_store IS DISTINCT FROM public.get_auth_user_store_id() THEN RAISE EXCEPTION 'Sem permissão.'; END IF;
    SELECT COUNT(*) AS n, COALESCE(SUM(total_net), 0) AS net, COALESCE(SUM(COALESCE(total_cogs, 0)), 0) AS cogs, MAX(created_at) AS last_at INTO r
      FROM public.sales
     WHERE status = 'CONCLUIDA' AND created_at >= date_trunc('month', NOW())
       AND (v_store = 'ALL' AND v_super OR store_id = v_store);
    RETURN jsonb_build_object('n', r.n, 'net', r.net, 'cogs', r.cogs, 'last', r.last_at);
END; $$;
REVOKE ALL ON FUNCTION public.fn_sales_fingerprint(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_sales_fingerprint(TEXT) TO authenticated;
