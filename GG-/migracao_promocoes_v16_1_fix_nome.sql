-- v16.1 — nome da promoção: valida e normaliza no servidor ANTES do INSERT (a constraint promotions_name_check mantém-se: 2 a 80 caracteres após TRIM).
-- Só substitui a função fn_promo_save; não altera tabelas, dados nem outras funções. Idempotente.
-- Verificação opcional da constraint real: SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'promotions_name_check';
CREATE OR REPLACE FUNCTION public.fn_promo_save(p_id UUID, p_name TEXT, p_type TEXT, p_value NUMERIC, p_starts TIMESTAMPTZ, p_ends TIMESTAMPTZ, p_product_ids TEXT[]) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_store TEXT := public.fn_catalog_store_id(ARRAY['ADMIN', 'GERENTE']); v_name TEXT := regexp_replace(BTRIM(COALESCE(p_name, ''), E' \t\r\n'), '\s+', ' ', 'g'); v_id UUID; v_ids TEXT[]; v_start TIMESTAMPTZ := p_starts; bad RECORD; v_conf JSONB; pr public.promotions%ROWTYPE;
BEGIN
    PERFORM public.fn_rate_limit('promosave:' || v_store, 30, 60);
    IF char_length(v_name) < 2 THEN RAISE EXCEPTION 'O nome da promoção deve ter pelo menos 2 caracteres.'; END IF;
    IF char_length(v_name) > 80 THEN RAISE EXCEPTION 'O nome da promoção pode ter no máximo 80 caracteres (tem %).', char_length(v_name); END IF;
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
            INSERT INTO public.promotions (store_id, name, discount_type, discount_value, starts_at, ends_at) VALUES (v_store, v_name, p_type, p_value, v_start, p_ends) RETURNING id INTO v_id;
        EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'Já existe uma promoção igual (mesmo nome e período).';
        END;
    ELSE
        SELECT * INTO pr FROM public.promotions WHERE id = p_id AND store_id = v_store FOR UPDATE;
        IF pr.id IS NULL THEN RAISE EXCEPTION 'Promoção não encontrada.'; END IF;
        IF pr.status <> 'ACTIVE' OR pr.starts_at <= NOW() THEN RAISE EXCEPTION 'Uma promoção iniciada ou terminada não pode ser editada; cancele-a e crie outra.'; END IF;
        BEGIN
            UPDATE public.promotions SET name = v_name, discount_type = p_type, discount_value = p_value, starts_at = v_start, ends_at = p_ends WHERE id = p_id;
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
