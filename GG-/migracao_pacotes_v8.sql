-- ==============================================================================
-- GEF | MIGRAÇÃO v8: novos pacotes de mensalidade 300, 500, 750 e 1000 (idempotente)
-- Pré-requisito: v7 (tabela public.ambassador_fee_packages). Não altera pacotes existentes.
-- ==============================================================================
INSERT INTO public.ambassador_fee_packages (id, name, monthly_fee, sort_order) VALUES
    ('pkg-300',  'Pacote 300',  300,  5),
    ('pkg-500',  'Pacote 500',  500,  6),
    ('pkg-750',  'Pacote 750',  750,  7),
    ('pkg-1000', 'Pacote 1000', 1000, 8)
ON CONFLICT (id) DO NOTHING;
