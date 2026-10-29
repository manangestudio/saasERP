-- =============================================================================
-- v10.1 — CORRECÇÃO DA LOJA VIRTUAL
--   1) "cannot execute INSERT in a read-only transaction"
--      As RPCs públicas fn_public_store / fn_public_products / fn_public_product
--      estavam marcadas STABLE (transacção só de leitura) mas chamam fn_rate_limit,
--      que faz INSERT em api_rate_limits. Passam a VOLATILE.
--   2) Todo produto do ERP passa a aparecer automaticamente na loja virtual
--      (products.published = TRUE por omissão). Continua possível desactivar/activar
--      por produto (botão "Loja" na lista de Produtos ou janela "Loja virtual").
-- Idempotente: pode ser executado mais de uma vez.
-- Executar no Supabase → SQL Editor, depois da migracao_loja_virtual_v10.sql.
-- =============================================================================

-- 1) Funções públicas: permitir escrita (rate limit)
ALTER FUNCTION public.fn_public_store(TEXT) VOLATILE;
ALTER FUNCTION public.fn_public_products(TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, INT) VOLATILE;
ALTER FUNCTION public.fn_public_product(TEXT, TEXT) VOLATILE;

-- 2) Publicação automática
DO $$
DECLARE v_default TEXT;
BEGIN
    SELECT column_default INTO v_default FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'products' AND column_name = 'published';
    -- Só na primeira execução (omissão ainda FALSE): publica os produtos já existentes.
    -- Nas execuções seguintes não mexe, para respeitar produtos que tenham sido desactivados de propósito.
    IF v_default IS NULL OR v_default ILIKE '%false%' THEN
        UPDATE public.products SET published = TRUE WHERE published IS DISTINCT FROM TRUE;
    END IF;
END $$;

ALTER TABLE public.products ALTER COLUMN published SET DEFAULT TRUE;

-- Garante que um INSERT que envie NULL também fica publicado
CREATE OR REPLACE FUNCTION public.fn_products_default_published() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.published IS NULL THEN NEW.published := TRUE; END IF;
    RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_products_default_published ON public.products;
CREATE TRIGGER trg_products_default_published BEFORE INSERT ON public.products
    FOR EACH ROW EXECUTE FUNCTION public.fn_products_default_published();

-- Permissões das RPCs públicas (reafirmadas)
GRANT EXECUTE ON FUNCTION public.fn_public_store(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_products(TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_product(TEXT, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Verificação (deve mostrar provolatile = 'v' nas três):
-- SELECT proname, provolatile FROM pg_proc WHERE proname IN ('fn_public_store','fn_public_products','fn_public_product');
