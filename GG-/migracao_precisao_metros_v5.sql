-- ==============================================================================
-- GEF | PRECISÃO PARA METROS / QUANTIDADES DECIMAIS  (opcional, idempotente)
--
-- Problema: stock e custos estavam em NUMERIC(12,2). Ao vender 0,125 m ou 1,333 m o stock
-- e o custo eram arredondados a 2 casas, e o lucro/estoque ficavam ligeiramente errados
-- (os lotes já usam 3 casas, por isso os dois lados deixavam de bater certo).
--
-- O que faz: ALARGA a precisão (não perde dados; 12,34 continua 12,340).
--   * stock (total, loja, armazém, pátio) e mínimo -> NUMERIC(14,3)
--   * preço de custo / venda / grosso do produto e preço da embalagem -> NUMERIC(14,4)
--   * preço unitário gravado em cada item de venda -> NUMERIC(14,4)
-- Cada alteração corre isolada: se uma falhar (ex.: vista dependente), as outras continuam
-- e é mostrado um aviso. NÃO altera funções, vendas existentes, policies nem permissões.
-- Executar no Supabase > SQL Editor. Pode ser repetida.
-- ==============================================================================
DO $$
DECLARE
    alvo RECORD;
BEGIN
    FOR alvo IN
        SELECT * FROM (VALUES
            ('products', 'current_stock',     'NUMERIC(14,3)'),
            ('products', 'stock_loja',        'NUMERIC(14,3)'),
            ('products', 'stock_armazem',     'NUMERIC(14,3)'),
            ('products', 'stock_patio',       'NUMERIC(14,3)'),
            ('products', 'min_stock',         'NUMERIC(14,3)'),
            ('products', 'cost_price',        'NUMERIC(14,4)'),
            ('products', 'sale_price',        'NUMERIC(14,4)'),
            ('products', 'wholesale_price',   'NUMERIC(14,4)'),
            ('product_packages', 'sale_price','NUMERIC(14,4)'),
            ('sale_items', 'unit_price',      'NUMERIC(14,4)')
        ) AS v(tabela, coluna, tipo)
    LOOP
        BEGIN
            IF EXISTS (SELECT 1 FROM information_schema.columns
                        WHERE table_schema = 'public'
                          AND table_name = alvo.tabela AND column_name = alvo.coluna) THEN
                EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I TYPE %s',
                               alvo.tabela, alvo.coluna, alvo.tipo);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'Não foi possível alargar %.%: %', alvo.tabela, alvo.coluna, SQLERRM;
        END;
    END LOOP;
END
$$;

NOTIFY pgrst, 'reload schema';
