-- ==============================================================================
-- GEF | PROMOÇÕES PROGRAMADAS (v16)  — idempotente. Correr DEPOIS de v10, v10_1, v11.
-- Não altera PDV, stock, comissões nem vendas. Preço base (products.sale_price) nunca é modificado.
-- Regras: sem acumulação; com várias promoções no mesmo produto vence o MENOR preço final
-- (empate: a mais antiga); a promoção legada do produto (promo_price) entra na mesma comparação.
-- Expiração: o preço é calculado no servidor com NOW() a cada leitura/encomenda ⇒ termina exactamente
-- em ends_at (exclusivo), sem depender de cron nem de o administrador abrir o sistema.
-- ==============================================================================
CREATE TABLE IF NOT EXISTS public.promotions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (LENGTH(TRIM(name)) BETWEEN 2 AND 80),
    discount_type TEXT NOT NULL CHECK (discount_type IN ('PERCENT', 'AMOUNT')),
    discount_value NUMERIC(12, 2) NOT NULL CHECK (discount_value > 0),
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'CANCELLED')),
    cancelled_at TIMESTAMPTZ,
    created_by UUID DEFAULT auth.uid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT promotions_period_chk CHECK (ends_at > starts_at AND ends_at - starts_at >= INTERVAL '1 minute' AND ends_at - starts_at <= INTERVAL '366 days'),
    CONSTRAINT promotions_percent_chk CHECK (discount_type <> 'PERCENT' OR discount_value <= 90)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_promotions_dup ON public.promotions(store_id, LOWER(TRIM(name)), starts_at, ends_at) WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_promotions_store ON public.promotions(store_id, starts_at DESC);
CREATE TABLE IF NOT EXISTS public.promotion_items (
    promotion_id UUID NOT NULL REFERENCES public.promotions(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    store_id TEXT NOT NULL,
    PRIMARY KEY (promotion_id, product_id)
);
CREATE INDEX IF NOT EXISTS idx_promotion_items_product ON public.promotion_items(product_id);

ALTER TABLE public.promotions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promotion_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "promotions_store_select" ON public.promotions;
CREATE POLICY "promotions_store_select" ON public.promotions FOR SELECT TO authenticated USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());
DROP POLICY IF EXISTS "promotion_items_store_select" ON public.promotion_items;
CREATE POLICY "promotion_items_store_select" ON public.promotion_items FOR SELECT TO authenticated USING (store_id = public.get_auth_user_store_id() OR public.fn_is_superadmin());
REVOKE ALL ON public.promotions, public.promotion_items FROM anon;
REVOKE INSERT, UPDATE, DELETE ON public.promotions, public.promotion_items FROM authenticated;   -- escrita só via RPC

-- Snapshots de preço no histórico da compra
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS unit_discount NUMERIC(12, 2) NOT NULL DEFAULT 0;
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS line_original NUMERIC(12, 2);
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS line_discount NUMERIC(12, 2) NOT NULL DEFAULT 0;
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS promotion_id UUID REFERENCES public.promotions(id) ON DELETE SET NULL;
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS promotion_name TEXT;
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS promo_starts_at TIMESTAMPTZ;
ALTER TABLE public.web_order_items ADD COLUMN IF NOT EXISTS promo_ends_at TIMESTAMPTZ;
ALTER TABLE public.web_orders ADD COLUMN IF NOT EXISTS subtotal_original NUMERIC(12, 2);
ALTER TABLE public.web_orders ADD COLUMN IF NOT EXISTS discount_total NUMERIC(12, 2) NOT NULL DEFAULT 0;

-- Compras concluídas não mudam retroactivamente (preços, quantidades, descontos e totais)
CREATE OR REPLACE FUNCTION public.fn_protect_order_prices() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'web_order_items' THEN
        IF (NEW.quantity, NEW.unit_price, NEW.base_price, NEW.line_total, NEW.unit_discount, NEW.line_original, NEW.line_discount, NEW.promotion_name, NEW.promo_applied)
           IS DISTINCT FROM (OLD.quantity, OLD.unit_price, OLD.base_price, OLD.line_total, OLD.unit_discount, OLD.line_original, OLD.line_discount, OLD.promotion_name, OLD.promo_applied) THEN
            RAISE EXCEPTION 'Os valores de uma compra registada não podem ser alterados.';
        END IF;
    ELSIF OLD.total <> 0 AND (NEW.total, NEW.subtotal_original, NEW.discount_total) IS DISTINCT FROM (OLD.total, OLD.subtotal_original, OLD.discount_total) THEN
        RAISE EXCEPTION 'Os valores de uma compra registada não podem ser alterados.';
    END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_protect_web_order_items ON public.web_order_items;
CREATE TRIGGER trg_protect_web_order_items BEFORE UPDATE ON public.web_order_items FOR EACH ROW EXECUTE FUNCTION public.fn_protect_order_prices();
DROP TRIGGER IF EXISTS trg_protect_web_orders ON public.web_orders;
CREATE TRIGGER trg_protect_web_orders BEFORE UPDATE ON public.web_orders FOR EACH ROW EXECUTE FUNCTION public.fn_protect_order_prices();

-- Preço aplicável AGORA + origem (única fonte de verdade: loja, carrinho e encomenda)
CREATE OR REPLACE FUNCTION public.fn_price_info(p public.products)
RETURNS TABLE (eff_price NUMERIC, eff_promo_id UUID, eff_promo_name TEXT, eff_starts TIMESTAMPTZ, eff_ends TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT x.price, x.pid, x.pname, x.s, x.e FROM (
        SELECT p.sale_price AS price, NULL::UUID AS pid, NULL::TEXT AS pname, NULL::TIMESTAMPTZ AS s, NULL::TIMESTAMPTZ AS e, 3 AS pri, NULL::TIMESTAMPTZ AS cr
        UNION ALL
        SELECT p.promo_price, NULL::UUID, 'Promoção do produto', p.promo_start, p.promo_end, 2, NULL::TIMESTAMPTZ
         WHERE COALESCE(p.promo_active, FALSE) AND p.promo_price IS NOT NULL AND p.promo_price >= 0 AND p.promo_price < p.sale_price
           AND (p.promo_start IS NULL OR p.promo_start <= NOW()) AND (p.promo_end IS NULL OR NOW() < p.promo_end)
        UNION ALL
        SELECT d.price, d.id, d.name, d.starts_at, d.ends_at, 1, d.created_at FROM (
            SELECT pr.id, pr.name, pr.starts_at, pr.ends_at, pr.created_at,
                   GREATEST(0, CASE WHEN pr.discount_type = 'PERCENT' THEN ROUND(p.sale_price * (1 - pr.discount_value / 100), 2) ELSE ROUND(p.sale_price - pr.discount_value, 2) END) AS price
              FROM public.promotion_items pi JOIN public.promotions pr ON pr.id = pi.promotion_id
             WHERE pi.product_id = p.id AND pr.store_id = p.store_id AND pr.status = 'ACTIVE' AND pr.starts_at <= NOW() AND NOW() < pr.ends_at) d
         WHERE d.price < p.sale_price
    ) x ORDER BY x.price ASC, x.pri ASC, x.cr ASC NULLS LAST, x.pid ASC NULLS LAST LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION public.fn_effective_price(p public.products) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT i.eff_price FROM public.fn_price_info(p) i;
$$;
REVOKE ALL ON FUNCTION public.fn_price_info(public.products) FROM PUBLIC, anon, authenticated;

-- Recibo/PDF: leitura única dos valores gravados (nunca recalcula)
CREATE OR REPLACE FUNCTION public.fn_web_order_receipt(p_order_id TEXT) RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object('code', o.code, 'created_at', o.created_at, 'customer_name', o.customer_name,
        'subtotal_original', COALESCE(o.subtotal_original, (SELECT SUM(COALESCE(i.line_original, ROUND(i.base_price * i.quantity, 2))) FROM public.web_order_items i WHERE i.order_id = o.id)),
        'discount_total', o.discount_total, 'total', o.total,
        'items', COALESCE((SELECT jsonb_agg(jsonb_build_object('name', i.product_name, 'code', i.product_code, 'unit', i.unit, 'color_name', i.color_name, 'color_hex', i.color_hex,
              'quantity', i.quantity, 'base_price', i.base_price, 'unit_price', i.unit_price, 'unit_discount', i.unit_discount,
              'line_original', COALESCE(i.line_original, ROUND(i.base_price * i.quantity, 2)), 'line_discount', i.line_discount, 'line_total', i.line_total,
              'promotion_name', i.promotion_name, 'promo_ends_at', i.promo_ends_at) ORDER BY i.id) FROM public.web_order_items i WHERE i.order_id = o.id), '[]'::JSONB))
      FROM public.web_orders o WHERE o.id = p_order_id;
$$;
REVOKE ALL ON FUNCTION public.fn_web_order_receipt(TEXT) FROM PUBLIC, anon, authenticated;

-- Carrinho: preços actuais (a loja chama ao abrir o carrinho e antes de enviar)
CREATE OR REPLACE FUNCTION public.fn_public_cart_prices(p_slug TEXT, p_items JSONB) RETURNS JSONB
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s public.stores%ROWTYPE;
BEGIN
    s := public.fn_vstore_resolve(p_slug);
    PERFORM public.fn_rate_limit('cartprice:' || public.fn_client_ip() || ':' || s.id, 60, 60);
    IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) > 30 THEN RAISE EXCEPTION 'Carrinho inválido.'; END IF;
    RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('product_id', p.id, 'price', p.sale_price, 'effective_price', i.eff_price, 'on_promo', i.eff_price < p.sale_price,
              'promo_name', i.eff_promo_name, 'promo_end', CASE WHEN i.eff_price < p.sale_price THEN i.eff_ends END))
        FROM public.products p CROSS JOIN LATERAL public.fn_price_info(p) i
        WHERE p.store_id = s.id AND p.published AND COALESCE(p.active, TRUE) AND p.id IN (SELECT jsonb_array_elements_text(p_items))), '[]'::JSONB);
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_cart_prices(TEXT, JSONB) TO anon, authenticated;

-- ------------------------------ ADMINISTRAÇÃO ------------------------------
CREATE OR REPLACE FUNCTION public.fn_promo_products(p_q TEXT DEFAULT NULL, p_category TEXT DEFAULT NULL) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']);
BEGIN
    RETURN COALESCE((SELECT jsonb_agg(to_jsonb(z)) FROM (
        SELECT p.id, p.name, p.code, p.category, p.sale_price AS price, i.eff_price AS effective_price
          FROM public.products p CROSS JOIN LATERAL public.fn_price_info(p) i
         WHERE p.store_id = v_store AND COALESCE(p.active, TRUE) AND p.sale_price > 0
           AND (NULLIF(TRIM(p_q), '') IS NULL OR public.fn_norm(p.name || ' ' || COALESCE(p.code, '')) LIKE '%' || public.fn_norm(p_q) || '%')
           AND (NULLIF(p_category, '') IS NULL OR p.category = p_category)
         ORDER BY p.name LIMIT 500) z), '[]'::JSONB);
END; $$;
REVOKE ALL ON FUNCTION public.fn_promo_products(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_promo_products(TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_promo_list() RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']);
BEGIN
    RETURN COALESCE((SELECT jsonb_agg(to_jsonb(z) ORDER BY z.starts_at DESC) FROM (
        SELECT pr.id, pr.name, pr.discount_type, pr.discount_value, pr.starts_at, pr.ends_at,
               CASE WHEN pr.status = 'CANCELLED' THEN 'CANCELADA' WHEN NOW() < pr.starts_at THEN 'AGENDADA' WHEN NOW() >= pr.ends_at THEN 'EXPIRADA' ELSE 'ATIVA' END AS state,
               (SELECT COUNT(*) FROM public.promotion_items pi WHERE pi.promotion_id = pr.id) AS products,
               (SELECT COALESCE(jsonb_agg(pi.product_id), '[]'::JSONB) FROM public.promotion_items pi WHERE pi.promotion_id = pr.id) AS product_ids,
               (SELECT COUNT(DISTINCT i.order_id) FROM public.web_order_items i WHERE i.promotion_id = pr.id) AS orders
          FROM public.promotions pr WHERE pr.store_id = v_store ORDER BY pr.starts_at DESC LIMIT 200) z), '[]'::JSONB);
END; $$;
REVOKE ALL ON FUNCTION public.fn_promo_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_promo_list() TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_promo_save(p_id UUID, p_name TEXT, p_type TEXT, p_value NUMERIC, p_starts TIMESTAMPTZ, p_ends TIMESTAMPTZ, p_product_ids TEXT[]) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']); v_id UUID; v_ids TEXT[]; v_start TIMESTAMPTZ := p_starts; bad RECORD; v_conf JSONB; pr public.promotions%ROWTYPE;
BEGIN
    PERFORM public.fn_rate_limit('promosave:' || v_store, 30, 60);
    IF p_type NOT IN ('PERCENT', 'AMOUNT') THEN RAISE EXCEPTION 'Tipo de desconto inválido.'; END IF;
    IF p_value IS NULL OR p_value <= 0 THEN RAISE EXCEPTION 'O desconto deve ser maior que zero.'; END IF;
    IF p_type = 'PERCENT' AND p_value > 90 THEN RAISE EXCEPTION 'A percentagem máxima de desconto é 90%%.'; END IF;
    IF p_starts IS NULL OR p_ends IS NULL THEN RAISE EXCEPTION 'Indique o início e o fim da promoção.'; END IF;
    IF v_start < NOW() - INTERVAL '2 minutes' THEN RAISE EXCEPTION 'O início não pode estar no passado.'; END IF;
    IF v_start < NOW() THEN v_start := NOW(); END IF;
    IF p_ends <= NOW() THEN RAISE EXCEPTION 'O fim da promoção já passou.'; END IF;
    IF p_ends - v_start < INTERVAL '1 minute' THEN RAISE EXCEPTION 'A duração mínima é 1 minuto.'; END IF;
    IF p_ends - v_start > INTERVAL '366 days' THEN RAISE EXCEPTION 'A duração máxima é 366 dias.'; END IF;
    SELECT ARRAY(SELECT DISTINCT x FROM unnest(p_product_ids) x WHERE x IS NOT NULL) INTO v_ids;
    IF COALESCE(array_length(v_ids, 1), 0) = 0 THEN RAISE EXCEPTION 'Seleccione pelo menos um produto.'; END IF;
    IF array_length(v_ids, 1) > 500 THEN RAISE EXCEPTION 'Máximo de 500 produtos por promoção.'; END IF;
    IF (SELECT COUNT(*) FROM public.products WHERE id = ANY (v_ids) AND store_id = v_store AND COALESCE(active, TRUE) AND sale_price > 0) <> array_length(v_ids, 1) THEN
        RAISE EXCEPTION 'Há produtos inválidos, inactivos ou de outra loja.'; END IF;
    IF p_type = 'AMOUNT' THEN
        SELECT name, sale_price INTO bad FROM public.products WHERE id = ANY (v_ids) AND sale_price <= p_value LIMIT 1;
        IF bad.name IS NOT NULL THEN RAISE EXCEPTION 'O desconto não pode ser igual ou superior ao preço de "%" (%).', bad.name, bad.sale_price; END IF;
    END IF;
    IF p_id IS NULL THEN
        BEGIN
            INSERT INTO public.promotions (store_id, name, discount_type, discount_value, starts_at, ends_at) VALUES (v_store, TRIM(p_name), p_type, p_value, v_start, p_ends) RETURNING id INTO v_id;
        EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'Já existe uma promoção igual (mesmo nome e período).';
        END;
    ELSE
        SELECT * INTO pr FROM public.promotions WHERE id = p_id AND store_id = v_store FOR UPDATE;
        IF pr.id IS NULL THEN RAISE EXCEPTION 'Promoção não encontrada.'; END IF;
        IF pr.status <> 'ACTIVE' OR pr.starts_at <= NOW() THEN RAISE EXCEPTION 'Uma promoção iniciada ou terminada não pode ser editada; cancele-a e crie outra.'; END IF;
        BEGIN
            UPDATE public.promotions SET name = TRIM(p_name), discount_type = p_type, discount_value = p_value, starts_at = v_start, ends_at = p_ends WHERE id = p_id;
        EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'Já existe uma promoção igual (mesmo nome e período).';
        END;
        DELETE FROM public.promotion_items WHERE promotion_id = p_id; v_id := p_id;
    END IF;
    INSERT INTO public.promotion_items (promotion_id, product_id, store_id) SELECT v_id, x, v_store FROM unnest(v_ids) x;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('product', z.pname, 'promotion', z.prname)), '[]'::JSONB) INTO v_conf FROM (
        SELECT DISTINCT p.name AS pname, o.name AS prname FROM public.promotion_items pi
          JOIN public.promotion_items oi ON oi.product_id = pi.product_id AND oi.promotion_id <> v_id
          JOIN public.promotions o ON o.id = oi.promotion_id AND o.status = 'ACTIVE' AND o.starts_at < p_ends AND o.ends_at > v_start
          JOIN public.products p ON p.id = pi.product_id WHERE pi.promotion_id = v_id LIMIT 30) z;
    RETURN jsonb_build_object('success', TRUE, 'id', v_id, 'starts_at', v_start, 'conflicts', v_conf);
END; $$;
REVOKE ALL ON FUNCTION public.fn_promo_save(UUID, TEXT, TEXT, NUMERIC, TIMESTAMPTZ, TIMESTAMPTZ, TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_promo_save(UUID, TEXT, TEXT, NUMERIC, TIMESTAMPTZ, TIMESTAMPTZ, TEXT[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_promo_cancel(p_id UUID) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']); n INT;
BEGIN
    UPDATE public.promotions SET status = 'CANCELLED', cancelled_at = NOW() WHERE id = p_id AND store_id = v_store AND status = 'ACTIVE' AND ends_at > NOW();
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n = 0 THEN RAISE EXCEPTION 'Promoção não encontrada ou já terminada.'; END IF;
    RETURN jsonb_build_object('success', TRUE);   -- compras já registadas mantêm os valores gravados
END; $$;
REVOKE ALL ON FUNCTION public.fn_promo_cancel(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_promo_cancel(UUID) TO authenticated;

-- ------------- Funções existentes, reescritas com patch mínimo (texto da v10/v11) -------------
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
                   p.sale_price AS price, public.fn_effective_price(p) AS effective_price, (public.fn_effective_price(p) < p.sale_price) AS on_promo,
                   (SELECT CASE WHEN i.eff_price < p.sale_price THEN i.eff_ends END FROM public.fn_price_info(p) i) AS promo_end,
                   (SELECT CASE WHEN i.eff_price < p.sale_price THEN i.eff_starts END FROM public.fn_price_info(p) i) AS promo_start, p.featured,
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
        'promo_end', (SELECT CASE WHEN i.eff_price < p.sale_price THEN i.eff_ends END FROM public.fn_price_info(p) i),
        'promo_start', (SELECT CASE WHEN i.eff_price < p.sale_price THEN i.eff_starts END FROM public.fn_price_info(p) i),
        'promo_name', (SELECT CASE WHEN i.eff_price < p.sale_price THEN i.eff_promo_name END FROM public.fn_price_info(p) i),
        'has_colors', p.has_colors, 'color_required', p.color_required, 'is_fractional', COALESCE(p.is_fractional, FALSE),
        'available', CASE WHEN p.has_colors THEN EXISTS (SELECT 1 FROM public.product_colors c WHERE c.product_id = p.id AND c.available AND (c.stock_qty IS NULL OR c.stock_qty > 0))
                          ELSE COALESCE(p.current_stock, 0) > 0 END,
        'images', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'path', i.path, 'thumb', i.thumb_path, 'main', i.is_main) ORDER BY i.is_main DESC, i.sort_order, i.created_at)
                              FROM public.product_images i WHERE i.product_id = p.id), '[]'::JSONB),
        'colors', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'hex', c.hex, 'image_id', c.image_id,
                                'available', (c.available AND (c.stock_qty IS NULL OR c.stock_qty > 0))) ORDER BY c.sort_order, c.name)
                              FROM public.product_colors c WHERE c.product_id = p.id), '[]'::JSONB));
END; $$;
CREATE OR REPLACE FUNCTION public.fn_public_create_order(p_slug TEXT, p_customer JSONB, p_items JSONB, p_idem TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    s public.stores%ROWTYPE; v_name TEXT; v_phone TEXT; v_id TEXT; v_code TEXT; it JSONB; pr public.products%ROWTYPE; col public.product_colors%ROWTYPE;
    v_qty NUMERIC; v_price NUMERIC; v_total NUMERIC := 0; v_ex RECORD; pinf RECORD; v_orig NUMERIC := 0; v_lo NUMERIC; v_lt NUMERIC;
BEGIN
    s := public.fn_vstore_resolve(p_slug);
    PERFORM public.fn_rate_limit('order:' || public.fn_client_ip() || ':' || s.id, 6, 600);
    IF p_idem IS NULL OR LENGTH(p_idem) < 8 OR LENGTH(p_idem) > 80 THEN RAISE EXCEPTION 'Pedido inválido (chave em falta).'; END IF;
    SELECT id, code, total INTO v_ex FROM public.web_orders WHERE store_id = s.id AND idempotency_key = p_idem;
    IF v_ex.id IS NOT NULL THEN RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'code', v_ex.code, 'total', v_ex.total, 'receipt', public.fn_web_order_receipt(v_ex.id)); END IF;

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
        RETURN jsonb_build_object('success', TRUE, 'duplicate', TRUE, 'code', v_ex.code, 'total', v_ex.total, 'receipt', public.fn_web_order_receipt(v_ex.id));
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

        SELECT * INTO pinf FROM public.fn_price_info(pr);   -- preço apurado no servidor, no instante da encomenda
        v_price := pinf.eff_price;
        v_lo := ROUND(pr.sale_price * v_qty, 2); v_lt := ROUND(v_price * v_qty, 2);
        INSERT INTO public.web_order_items (order_id, store_id, product_id, product_name, product_code, unit, color_id, color_name, color_hex,
                                            quantity, unit_price, base_price, promo_applied, line_total, unit_discount, line_original, line_discount,
                                            promotion_id, promotion_name, promo_starts_at, promo_ends_at)
        VALUES (v_id, s.id, pr.id, pr.name, pr.code, COALESCE(pr.sale_unit, pr.unit), col.id, col.name, col.hex,
                v_qty, v_price, pr.sale_price, v_price < pr.sale_price, v_lt, pr.sale_price - v_price, v_lo, v_lo - v_lt,
                CASE WHEN v_price < pr.sale_price THEN pinf.eff_promo_id END, CASE WHEN v_price < pr.sale_price THEN pinf.eff_promo_name END,
                CASE WHEN v_price < pr.sale_price THEN pinf.eff_starts END, CASE WHEN v_price < pr.sale_price THEN pinf.eff_ends END);
        v_total := v_total + v_lt; v_orig := v_orig + v_lo;
    END LOOP;

    UPDATE public.web_orders SET total = v_total, subtotal_original = v_orig, discount_total = v_orig - v_total WHERE id = v_id;
    RETURN jsonb_build_object('success', TRUE, 'duplicate', FALSE, 'code', v_code, 'total', v_total, 'receipt', public.fn_web_order_receipt(v_id));
END; $$;
GRANT EXECUTE ON FUNCTION public.fn_public_create_order(TEXT, JSONB, JSONB, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_store_order_get(p_order_id TEXT) RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE', 'ESTOQUISTA', 'CASHIER']); o public.web_orders%ROWTYPE;
BEGIN
    SELECT * INTO o FROM public.web_orders WHERE id = p_order_id AND store_id = v_store;
    IF o.id IS NULL THEN RAISE EXCEPTION 'Encomenda não encontrada.'; END IF;
    RETURN to_jsonb(o) || jsonb_build_object('items', COALESCE((SELECT jsonb_agg(jsonb_build_object('product_id', i.product_id, 'name', i.product_name, 'code', i.product_code, 'unit', i.unit,
              'color_name', i.color_name, 'color_hex', i.color_hex, 'quantity', i.quantity, 'unit_price', i.unit_price, 'base_price', i.base_price, 'promo_applied', i.promo_applied, 'line_total', i.line_total, 'unit_discount', i.unit_discount,
              'line_original', COALESCE(i.line_original, ROUND(i.base_price * i.quantity, 2)), 'line_discount', i.line_discount, 'promotion_name', i.promotion_name, 'promo_ends_at', i.promo_ends_at) ORDER BY i.id)
              FROM public.web_order_items i WHERE i.order_id = o.id), '[]'::JSONB));
END; $$;
REVOKE ALL ON FUNCTION public.fn_store_order_get(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_store_order_get(TEXT) TO authenticated;
