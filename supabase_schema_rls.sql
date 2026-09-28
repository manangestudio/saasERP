-- ==============================================================================
-- GEF - GESTÃO FINANCEIRA | SCHEMA SQL & RLS SUPABASE ROBUSTO
-- Compatível com PostgreSQL / Supabase
-- ==============================================================================

-- 1. EXTENSÕES
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. TABELA DE FILIAIS / LOJAS (STORES) & LICENCIAMENTO SAAS
CREATE TABLE IF NOT EXISTS public.stores (
    id TEXT PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    trade_name TEXT,
    nuit_nif TEXT,
    city TEXT DEFAULT 'Maputo',
    province TEXT,
    address TEXT,
    phone TEXT,
    email TEXT,
    currency TEXT DEFAULT 'MT', -- Suporte: MT (Moçambique), Kz (Angola), R$ (Brasil), R (RSA), $ (EUA)
    language TEXT DEFAULT 'pt', -- Suporte: pt (Português), en (English)
    is_headquarters BOOLEAN DEFAULT FALSE,
    valor_mensalidade NUMERIC(12, 2) DEFAULT 4500.00, -- Valor manual de mensalidade da filial
    data_inicio_teste TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    data_fim_teste DATE NOT NULL DEFAULT (CURRENT_DATE + INTERVAL '30 days'), -- Vencimento da subscrição
    acesso_ativo BOOLEAN DEFAULT TRUE,
    motivo_bloqueio TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 3. PERFIS DE USUÁRIO (PROFILES) SINCRONIZADOS COM AUTH.USERS
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT UNIQUE NOT NULL,
    full_name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('SUPERADMIN', 'ADMIN', 'GERENTE', 'CASHIER', 'ESTOQUISTA', 'EMBAIXADOR')),
    store_id TEXT REFERENCES public.stores(id) ON DELETE SET NULL,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. CLIENTES, CRÉDITO (FIADO) E SUBSCRIÇÃO / MENSALIDADE
CREATE TABLE IF NOT EXISTS public.customers (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    document TEXT,
    phone TEXT,
    email TEXT,
    address TEXT,
    credit_limit NUMERIC(12, 2) DEFAULT 0.00,
    current_debt NUMERIC(12, 2) DEFAULT 0.00,
    -- Mensalidade manual do cliente e vencimento:
    subscription_fee NUMERIC(12, 2) DEFAULT NULL,
    subscription_end_date DATE DEFAULT NULL,
    is_subscription_active BOOLEAN GENERATED ALWAYS AS (
        subscription_end_date IS NULL OR subscription_end_date >= CURRENT_DATE
    ) STORED,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 5. PRODUTOS & MATERIAIS DE CONSTRUÇÃO
CREATE TABLE IF NOT EXISTS public.products (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    barcode TEXT,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    unit TEXT DEFAULT 'UN',
    cost_price NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    sale_price NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    wholesale_price NUMERIC(12, 2),
    min_stock NUMERIC(12, 2) DEFAULT 5.00,
    current_stock NUMERIC(12, 2) DEFAULT 0.00,
    stock_loja NUMERIC(12, 2) DEFAULT 0.00,
    stock_armazem NUMERIC(12, 2) DEFAULT 0.00,
    stock_patio NUMERIC(12, 2) DEFAULT 0.00,
    is_fractional BOOLEAN DEFAULT FALSE,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 6. VENDAS (SALES)
CREATE TABLE IF NOT EXISTS public.sales (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    customer_id TEXT REFERENCES public.customers(id) ON DELETE SET NULL,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    total_gross NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    discount NUMERIC(12, 2) DEFAULT 0.00,
    total_net NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    payment_method TEXT NOT NULL CHECK (payment_method IN ('DINHEIRO', 'M-PESA', 'E-MOLA', 'POS_CARTAO', 'TRANSFERENCIA', 'A_PRAZO', 'FIADO', 'CREDITO_FIADO', 'MULTIPLE')),
    status TEXT NOT NULL DEFAULT 'CONCLUIDA' CHECK (status IN ('CONCLUIDA', 'CANCELADA', 'PENDENTE')),
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 7. ITENS DA VENDA (SALE ITEMS)
CREATE TABLE IF NOT EXISTS public.sale_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sale_id TEXT NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    quantity NUMERIC(12, 3) NOT NULL,
    unit_price NUMERIC(12, 2) NOT NULL,
    total_price NUMERIC(12, 2) NOT NULL,
    location TEXT DEFAULT 'LOJA' CHECK (location IN ('LOJA', 'ARMAZEM', 'PATIO'))
);

-- 8. FECHAMENTO CEGO & SESSÕES DE CAIXA
CREATE TABLE IF NOT EXISTS public.cash_sessions (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    opened_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    closed_at TIMESTAMP WITH TIME ZONE,
    opening_balance NUMERIC(12, 2) DEFAULT 0.00,
    declared_cash NUMERIC(12, 2),
    expected_cash NUMERIC(12, 2),
    difference NUMERIC(12, 2),
    is_closed BOOLEAN DEFAULT FALSE,
    notes TEXT
);

-- 9. PROGRAMA DE EMBAIXADORES & COMISSÕES
CREATE TABLE IF NOT EXISTS public.ambassadors (
    id TEXT PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    phone TEXT NOT NULL,
    pix_mpesa TEXT NOT NULL,
    referral_code TEXT UNIQUE NOT NULL,
    commission_rate NUMERIC(5, 2) DEFAULT 10.00,
    total_earned NUMERIC(12, 2) DEFAULT 0.00,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==============================================================================
-- 10. FUNÇÕES AUXILIARES & VERIFICAÇÃO DE ASSINATURA / TRAVA RLS
-- ==============================================================================

-- Função para verificar se a loja está liberada ou se a subscrição expirou
CREATE OR REPLACE FUNCTION public.fn_is_store_unlocked(check_store_id TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    store_record RECORD;
BEGIN
    SELECT acesso_ativo, data_fim_teste INTO store_record
    FROM public.stores
    WHERE id = check_store_id;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Se marcado como inativo ou se a data de fim já foi atingida (<= CURRENT_DATE)
    IF store_record.acesso_ativo = FALSE OR store_record.data_fim_teste < CURRENT_DATE THEN
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==============================================================================
-- 11. ROW LEVEL SECURITY (RLS) ROBUSTO
-- ==============================================================================

ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ambassadors ENABLE ROW LEVEL SECURITY;

-- Helper para recuperar a role do usuário logado
CREATE OR REPLACE FUNCTION public.get_auth_user_role()
RETURNS TEXT AS $$
    SELECT role FROM public.profiles WHERE id = auth.uid();
$$ LANGUAGE sql STABLE;

-- Helper para recuperar a loja do usuário logado
CREATE OR REPLACE FUNCTION public.get_auth_user_store_id()
RETURNS TEXT AS $$
    SELECT store_id FROM public.profiles WHERE id = auth.uid();
$$ LANGUAGE sql STABLE;

-- POLÍTICAS: STORES
-- Superadmin tem acesso total
CREATE POLICY "Superadmin tem acesso irrestrito a stores"
ON public.stores FOR ALL
TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');

-- Usuários comuns podem visualizar apenas sua loja
CREATE POLICY "Usuários podem ver a própria loja"
ON public.stores FOR SELECT
TO authenticated
USING (id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- ADMIN da própria loja pode editar dados de perfil da loja (nome, contato, moeda, idioma,
-- recibo). Os campos de assinatura/financeiro (valor_mensalidade, data_fim_teste,
-- acesso_ativo, motivo_bloqueio) são protegidos por trigger abaixo: só SUPERADMIN os altera,
-- mesmo que um ADMIN tente enviá-los no mesmo UPDATE.
CREATE POLICY "Admin da loja atualiza o perfil da própria loja"
ON public.stores FOR UPDATE
TO authenticated
USING (public.get_auth_user_role() = 'ADMIN' AND id = public.get_auth_user_store_id())
WITH CHECK (public.get_auth_user_role() = 'ADMIN' AND id = public.get_auth_user_store_id());

CREATE OR REPLACE FUNCTION public.fn_protect_store_subscription_fields()
RETURNS TRIGGER AS $$
BEGIN
    IF public.get_auth_user_role() <> 'SUPERADMIN' THEN
        NEW.valor_mensalidade := OLD.valor_mensalidade;
        NEW.data_fim_teste := OLD.data_fim_teste;
        NEW.acesso_ativo := OLD.acesso_ativo;
        NEW.motivo_bloqueio := OLD.motivo_bloqueio;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_protect_store_subscription ON public.stores;
CREATE TRIGGER trg_protect_store_subscription
    BEFORE UPDATE ON public.stores
    FOR EACH ROW EXECUTE FUNCTION public.fn_protect_store_subscription_fields();

-- POLÍTICAS: PROFILES
CREATE POLICY "Superadmin gerencia todos os perfis"
ON public.profiles FOR ALL
TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "Usuários visualizam perfis de sua própria loja"
ON public.profiles FOR SELECT
TO authenticated
USING (store_id = public.get_auth_user_store_id() OR id = auth.uid());

-- DECISÃO NECESSÁRIA: a regra abaixo é um ponto de partida mínimo e seguro,
-- não uma regra de negócio definitiva. Ela permite que um ADMIN da própria
-- loja edite (ative, mude papel/loja) perfis que já pertencem à sua loja OU
-- que ainda não têm loja atribuída (novos cadastros). Avaliar com o cliente
-- se isso é suficiente ou se a atribuição de papel deve passar por uma RPC
-- dedicada com auditoria (recomendado para produção).
CREATE POLICY "Admin da loja gerencia perfis da própria loja ou não atribuídos"
ON public.profiles FOR UPDATE
TO authenticated
USING (
    public.get_auth_user_role() = 'ADMIN'
    AND (store_id = public.get_auth_user_store_id() OR store_id IS NULL)
)
WITH CHECK (
    public.get_auth_user_role() = 'ADMIN'
    AND store_id = public.get_auth_user_store_id()
    AND role <> 'SUPERADMIN'
);

-- POLÍTICAS: PRODUCTS
-- Leitura permitida para a própria loja
CREATE POLICY "Leitura de produtos da filial"
ON public.products FOR SELECT
TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- Modificação SOMENTE se a loja NÃO estiver com a trava RLS ativada (Subscrição Válida)
CREATE POLICY "Modificação de produtos sujeita à trava de subscrição ativa"
ON public.products FOR INSERT
TO authenticated
WITH CHECK (
    (public.get_auth_user_role() = 'SUPERADMIN') OR
    (store_id = public.get_auth_user_store_id() AND public.fn_is_store_unlocked(store_id) = TRUE)
);

CREATE POLICY "Atualização de produtos sujeita à trava de subscrição ativa"
ON public.products FOR UPDATE
TO authenticated
USING (
    (public.get_auth_user_role() = 'SUPERADMIN') OR
    (store_id = public.get_auth_user_store_id() AND public.fn_is_store_unlocked(store_id) = TRUE)
)
WITH CHECK (
    (public.get_auth_user_role() = 'SUPERADMIN') OR
    (store_id = public.get_auth_user_store_id() AND public.fn_is_store_unlocked(store_id) = TRUE)
);

CREATE POLICY "Exclusão de produtos restrita a ADMIN/SUPERADMIN"
ON public.products FOR DELETE
TO authenticated
USING (
    public.get_auth_user_role() = 'SUPERADMIN' OR
    (public.get_auth_user_role() = 'ADMIN' AND store_id = public.get_auth_user_store_id())
);

-- POLÍTICAS: SALES & SALE ITEMS (TRAVA RLS AUTOMÁTICA NO VENCIMENTO)
CREATE POLICY "Leitura de vendas da própria loja"
ON public.sales FOR SELECT
TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- Vendas NUNCA são inseridas diretamente pelo cliente: só a RPC fn_process_atomic_sale
-- (SECURITY DEFINER, que ignora RLS) pode criar uma venda, garantindo baixa de estoque,
-- kardex e caixa na mesma transação. Sem policy de INSERT aqui, o INSERT direto é negado.

CREATE POLICY "Leitura de itens da venda"
ON public.sale_items FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.sales s 
        WHERE s.id = sale_items.sale_id 
        AND (s.store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')
    )
);

-- Itens de venda também só são gravados pela RPC (SECURITY DEFINER). Sem policy de
-- INSERT/UPDATE/DELETE para o cliente autenticado.

-- POLÍTICAS: CUSTOMERS & FIADO
CREATE POLICY "Acesso aos clientes da loja"
ON public.customers FOR ALL
TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- POLÍTICAS: SESSÕES DE CAIXA
-- Leitura livre por loja; abertura/fechamento/sangria/reforço só pelas RPCs
-- (fn_open_cash_session, fn_close_cash_session, fn_register_cash_movement), nunca por
-- INSERT/UPDATE direto do cliente -- isso impede adulterar o valor contado/esperado.
CREATE POLICY "Leitura de caixa por filial"
ON public.cash_sessions FOR SELECT
TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- ==============================================================================
-- 12. VIEWS DE LEMBRETE DE RENOVAÇÃO (5 DIAS ANTES DE EXPIRAR)
-- ==============================================================================

-- Visão para monitorar lojas com subscrição vencendo em 5 dias ou menos:
CREATE OR REPLACE VIEW public.vw_stores_renewal_reminders AS
SELECT 
    id,
    code,
    name,
    phone,
    email,
    valor_mensalidade,
    data_fim_teste,
    (data_fim_teste - CURRENT_DATE) AS dias_restantes,
    CASE 
        WHEN data_fim_teste < CURRENT_DATE THEN 'EXPIRADO_TRAVADO'
        WHEN (data_fim_teste - CURRENT_DATE) <= 5 THEN 'AVISO_5_DIAS'
        ELSE 'REGULAR'
    END AS status_alerta
FROM public.stores
WHERE data_fim_teste - CURRENT_DATE <= 5;

-- Visão para monitorar clientes com mensalidade vencendo em 5 dias ou menos:
CREATE OR REPLACE VIEW public.vw_customers_renewal_reminders AS
SELECT 
    id,
    store_id,
    name,
    phone,
    subscription_fee,
    subscription_end_date,
    (subscription_end_date - CURRENT_DATE) AS dias_restantes,
    current_debt,
    CASE 
        WHEN subscription_end_date < CURRENT_DATE THEN 'MENSALIDADE_VENCIDA'
        WHEN (subscription_end_date - CURRENT_DATE) <= 5 THEN 'AVISO_5_DIAS'
        ELSE 'REGULAR'
    END AS status_renovacao
FROM public.customers
WHERE subscription_end_date IS NOT NULL 
  AND (subscription_end_date - CURRENT_DATE) <= 5;

-- ==============================================================================
-- 13. TRIGGER DE SINCRONIZAÇÃO AUTOMÁTICA DE AUTH.USERS COM PROFILES
-- ==============================================================================

-- SEGURANÇA CRÍTICA: esta função NUNCA deve derivar o papel (role) a partir de
-- dados fornecidos pelo próprio usuário (raw_user_meta_data) nem do padrão do
-- e-mail. Qualquer pessoa pode chamar auth.signUp() com metadata arbitrária ou
-- escolher o e-mail que quiser (ex: "admin@qualquercoisa.com"); confiar nisso
-- para atribuir ADMIN/SUPERADMIN é uma escalação de privilégio trivial.
--
-- Todo novo usuário nasce como CASHIER, sem loja atribuída (store_id NULL) e
-- INATIVO. Um ADMIN ou SUPERADMIN precisa entrar em Configurações/Usuários e
-- atribuir explicitamente papel, loja e ativar o usuário (via UPDATE em
-- public.profiles, permitido pelas policies abaixo apenas para quem já é
-- SUPERADMIN ou ADMIN da própria loja).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name, role, store_id, active)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'full_name'), ''), split_part(NEW.email, '@', 1)),
        'CASHIER',
        NULL,
        FALSE
    )
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- ==============================================================================
-- 14. SEED INICIAL DE LOJAS
-- ==============================================================================
INSERT INTO public.stores (id, code, name, trade_name, nuit_nif, city, currency, is_headquarters, valor_mensalidade, data_fim_teste, acesso_ativo)
VALUES 
('store-001', 'LOJA-01', 'GEF - Ferragens & Materiais Matriz', 'GEF Ferragens Matriz', '400192837', 'Maputo', 'MT', TRUE, 5500.00, CURRENT_DATE + INTERVAL '30 days', TRUE),
('store-002', 'LOJA-02', 'GEF - Unidade Matola Canteiro', 'GEF Matola', '400192838', 'Matola', 'MT', FALSE, 4500.00, CURRENT_DATE + INTERVAL '30 days', TRUE)
ON CONFLICT (id) DO NOTHING;

-- ==============================================================================
-- 15. CATEGORIAS, UNIDADES, EMBALAGENS E LOTES (FEFO)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.categories (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.units (
    id TEXT PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    is_fractional BOOLEAN DEFAULT FALSE
);

-- Embalagens/conversões de um produto (ex: 1 Saco = 50 UN)
CREATE TABLE IF NOT EXISTS public.product_packages (
    id TEXT PRIMARY KEY,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    packaging_name TEXT NOT NULL,
    multiplier_to_base NUMERIC(12, 4) NOT NULL DEFAULT 1,
    unit_id TEXT REFERENCES public.units(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Lotes por produto para rastreio FEFO (data de validade)
CREATE TABLE IF NOT EXISTS public.batches (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    batch_number TEXT,
    supplier_id TEXT,
    initial_quantity_base NUMERIC(12, 3) NOT NULL,
    current_quantity_base NUMERIC(12, 3) NOT NULL,
    cost_per_base NUMERIC(12, 4) NOT NULL DEFAULT 0,
    expiry_date DATE,
    status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'EXHAUSTED')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_batches_product_expiry ON public.batches(product_id, expiry_date) WHERE status = 'ACTIVE';

-- ==============================================================================
-- 16. FORNECEDORES, COMPRAS E MOVIMENTOS DE ESTOQUE
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.suppliers (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    phone TEXT,
    email TEXT,
    address TEXT,
    nuit_nif TEXT,
    notes TEXT,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.purchases (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    supplier_id TEXT REFERENCES public.suppliers(id) ON DELETE SET NULL,
    supplier_name TEXT,
    invoice_number TEXT,
    destination_location TEXT DEFAULT 'ARMAZEM' CHECK (destination_location IN ('LOJA', 'ARMAZEM', 'PATIO')),
    total_cost NUMERIC(12, 2) NOT NULL DEFAULT 0,
    payment_status TEXT DEFAULT 'PAGO',
    notes TEXT,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.purchase_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id TEXT NOT NULL REFERENCES public.purchases(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    quantity_purchased NUMERIC(12, 3) NOT NULL,
    unit_cost NUMERIC(12, 4) NOT NULL DEFAULT 0,
    new_sale_price NUMERIC(12, 2),
    batch_number TEXT,
    expiry_date DATE
);

-- Kardex: toda movimentação real de estoque (entrada, saída, transferência, ajuste, perda)
-- é a fonte de verdade do estoque -- nunca só "stock = stock - qty" isolado.
CREATE TABLE IF NOT EXISTS public.stock_movements (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    batch_id TEXT REFERENCES public.batches(id) ON DELETE SET NULL,
    movement_type TEXT NOT NULL CHECK (movement_type IN ('ENTRADA_COMPRA', 'SAIDA_VENDA', 'ESTORNO_VENDA', 'TRANSFERENCIA', 'PERDA', 'AJUSTE_INVENTARIO')),
    quantity_base NUMERIC(12, 3) NOT NULL,
    location TEXT CHECK (location IN ('LOJA', 'ARMAZEM', 'PATIO')),
    reference_type TEXT,
    reference_id TEXT,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.transfers (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    quantity_base NUMERIC(12, 3) NOT NULL,
    from_location TEXT NOT NULL CHECK (from_location IN ('LOJA', 'ARMAZEM', 'PATIO')),
    to_location TEXT NOT NULL CHECK (to_location IN ('LOJA', 'ARMAZEM', 'PATIO')),
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.losses (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    product_id TEXT NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    quantity_base NUMERIC(12, 3) NOT NULL,
    location TEXT DEFAULT 'LOJA' CHECK (location IN ('LOJA', 'ARMAZEM', 'PATIO')),
    reason TEXT NOT NULL,
    total_loss_cost NUMERIC(12, 2) DEFAULT 0,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==============================================================================
-- 17. CAIXA: REGISTRADORAS, MOVIMENTOS (SANGRIA/REFORÇO/VENDA)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.cash_movements (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL REFERENCES public.cash_sessions(id) ON DELETE CASCADE,
    movement_type TEXT NOT NULL CHECK (movement_type IN ('INITIAL', 'SALE', 'SANGRIA_BANK', 'SANGRIA_SAFE', 'REFORCO', 'DESPESA', 'ESTORNO', 'OUTRO')),
    payment_method TEXT,
    amount NUMERIC(12, 2) NOT NULL,
    reason TEXT,
    destination TEXT,
    notes TEXT,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.expenses (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    session_id TEXT REFERENCES public.cash_sessions(id) ON DELETE SET NULL,
    category TEXT NOT NULL,
    description TEXT,
    amount NUMERIC(12, 2) NOT NULL,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==============================================================================
-- 18. CRÉDITO/FIADO, ORÇAMENTOS, ENTREGAS, INVENTÁRIO E AUDITORIA
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.credit_transactions (
    id TEXT PRIMARY KEY,
    customer_id TEXT NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('DEBITO_VENDA', 'PAGAMENTO', 'ESTORNO')),
    amount NUMERIC(12, 2) NOT NULL,
    balance_after NUMERIC(12, 2) NOT NULL,
    notes TEXT,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.quotes (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    customer_id TEXT REFERENCES public.customers(id) ON DELETE SET NULL,
    customer_name TEXT,
    items JSONB NOT NULL DEFAULT '[]',
    total NUMERIC(12, 2) NOT NULL DEFAULT 0,
    valid_until DATE,
    status TEXT NOT NULL DEFAULT 'RASCUNHO' CHECK (status IN ('RASCUNHO', 'PENDENTE', 'ENVIADO', 'APROVADO', 'RECUSADO', 'CONVERTIDO')),
    converted_sale_id TEXT REFERENCES public.sales(id) ON DELETE SET NULL,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.deliveries (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    sale_id TEXT REFERENCES public.sales(id) ON DELETE SET NULL,
    customer_name TEXT,
    address TEXT,
    driver_name TEXT,
    status TEXT NOT NULL DEFAULT 'PENDENTE' CHECK (status IN ('PENDENTE', 'EM_TRANSITO', 'ENTREGUE', 'CANCELADA')),
    scheduled_date DATE,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.inventories (
    id TEXT PRIMARY KEY,
    store_id TEXT NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    code TEXT NOT NULL,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    reconciled BOOLEAN DEFAULT FALSE,
    notes TEXT,
    total_items_audited INT DEFAULT 0,
    total_divergent_items INT DEFAULT 0,
    total_divergence_value NUMERIC(12, 2) DEFAULT 0,
    items JSONB NOT NULL DEFAULT '[]',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
    id TEXT PRIMARY KEY,
    store_id TEXT REFERENCES public.stores(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    entity TEXT,
    entity_id TEXT,
    details TEXT,
    operator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==============================================================================
-- 19. PROGRAMA DE EMBAIXADORES: LOJAS INDICADAS E PAGAMENTOS (dados reais, não seed fake)
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.ambassador_referred_stores (
    id TEXT PRIMARY KEY,
    ambassador_id TEXT NOT NULL REFERENCES public.ambassadors(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    owner_name TEXT,
    phone TEXT,
    city TEXT,
    monthly_fee NUMERIC(12, 2) DEFAULT 0,
    payment_status TEXT DEFAULT 'PENDENTE' CHECK (payment_status IN ('PAGO', 'PENDENTE', 'ATRASADO')),
    last_payment_date DATE,
    next_due_date DATE,
    commission_rate NUMERIC(5, 2) DEFAULT 15,
    contract_duration_months INT DEFAULT 12,
    months_active INT DEFAULT 0,
    total_commission_earned NUMERIC(12, 2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.ambassador_payouts (
    id TEXT PRIMARY KEY,
    ambassador_id TEXT NOT NULL REFERENCES public.ambassadors(id) ON DELETE CASCADE,
    amount NUMERIC(12, 2) NOT NULL,
    method TEXT,
    receipt TEXT,
    status TEXT DEFAULT 'LIQUIDADO',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS pending_commissions NUMERIC(12, 2) DEFAULT 0;

-- ==============================================================================
-- 20. RLS DAS NOVAS TABELAS (mesmo padrão: isolamento por loja + SUPERADMIN global)
-- ==============================================================================

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.losses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ambassador_referred_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ambassador_payouts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;

-- Padrão de policy reutilizado: leitura/escrita restrita à própria loja, SUPERADMIN vê tudo.
-- (units e product_packages/purchase_items não têm store_id direto -- ver policies específicas abaixo)

CREATE POLICY "categories_by_store" ON public.categories FOR ALL TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "units_readable_by_all_authenticated" ON public.units FOR SELECT TO authenticated USING (true);
CREATE POLICY "units_managed_by_superadmin" ON public.units FOR INSERT TO authenticated WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');
CREATE POLICY "units_updated_by_superadmin" ON public.units FOR UPDATE TO authenticated USING (public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "product_packages_via_product_store" ON public.product_packages FOR ALL TO authenticated
USING (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_packages.product_id AND (p.store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')))
WITH CHECK (EXISTS (SELECT 1 FROM public.products p WHERE p.id = product_packages.product_id AND (p.store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')));

-- batches: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "batches_by_store_select" ON public.batches FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "suppliers_by_store" ON public.suppliers FOR ALL TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- purchases: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "purchases_by_store_select" ON public.purchases FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- purchase_items: só leitura; escrita exclusiva da RPC fn_confirm_purchase.
CREATE POLICY "purchase_items_via_purchase_store_select" ON public.purchase_items FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.purchases pu WHERE pu.id = purchase_items.purchase_id AND (pu.store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')));

-- stock_movements: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "stock_movements_by_store_select" ON public.stock_movements FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- transfers: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "transfers_by_store_select" ON public.transfers FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- losses: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "losses_by_store_select" ON public.losses FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- cash_movements: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "cash_movements_via_session_store_select" ON public.cash_movements FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- expenses: só leitura; escrita exclusiva da RPC fn_register_cash_movement (tipo DESPESA).
CREATE POLICY "expenses_by_store_select" ON public.expenses FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- credit_transactions: só leitura; escrita exclusiva das RPCs de venda/estorno/pagamento.
CREATE POLICY "credit_tx_via_customer_store_select" ON public.credit_transactions FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.customers c WHERE c.id = credit_transactions.customer_id AND (c.store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')));

CREATE POLICY "quotes_by_store" ON public.quotes FOR ALL TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "deliveries_by_store" ON public.deliveries FOR ALL TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- inventories: só leitura para o cliente; toda escrita acontece dentro das RPCs (SECURITY DEFINER).
CREATE POLICY "inventories_by_store_select" ON public.inventories FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- Auditoria: leitura restrita à loja/SUPERADMIN; escrita só via SECURITY DEFINER (RPCs), nunca INSERT direto do cliente.
CREATE POLICY "audit_logs_read_by_store" ON public.audit_logs FOR SELECT TO authenticated
USING (store_id = public.get_auth_user_store_id() OR public.get_auth_user_role() = 'SUPERADMIN');

-- A tabela ambassadors tinha RLS ativado sem NENHUMA policy (bloqueava tudo, até o SUPERADMIN).
CREATE POLICY "ambassadors_superadmin_full_access" ON public.ambassadors FOR ALL TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN')
WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "ambassadors_self_read" ON public.ambassadors FOR SELECT TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "ambassador_referred_stores_via_ambassador" ON public.ambassador_referred_stores FOR ALL TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN' OR EXISTS (SELECT 1 FROM public.ambassadors a WHERE a.id = ambassador_referred_stores.ambassador_id AND a.user_id = auth.uid()))
WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');

CREATE POLICY "ambassador_payouts_via_ambassador" ON public.ambassador_payouts FOR ALL TO authenticated
USING (public.get_auth_user_role() = 'SUPERADMIN' OR EXISTS (SELECT 1 FROM public.ambassadors a WHERE a.id = ambassador_payouts.ambassador_id AND a.user_id = auth.uid()))
WITH CHECK (public.get_auth_user_role() = 'SUPERADMIN');

-- ==============================================================================
-- 21. RPCs ATÔMICAS (Regra 27: operações críticas nunca ficam parcialmente gravadas)
-- ==============================================================================

-- Verificação de acesso reutilizada pelas RPCs SECURITY DEFINER (que ignoram RLS):
-- só SUPERADMIN ou usuário ATIVO da própria loja pode operar sobre p_store_id.
CREATE OR REPLACE FUNCTION public.fn_assert_store_access(p_store_id TEXT, p_allowed_roles TEXT[] DEFAULT NULL)
RETURNS VOID AS $$
DECLARE
    v_role TEXT := public.get_auth_user_role();
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Sessão não autenticada.';
    END IF;
    IF v_role = 'SUPERADMIN' THEN RETURN; END IF;
    IF p_store_id IS DISTINCT FROM public.get_auth_user_store_id() THEN
        RAISE EXCEPTION 'Sem permissão para operar nesta loja.';
    END IF;
    IF p_allowed_roles IS NOT NULL AND NOT (v_role = ANY(p_allowed_roles)) THEN
        RAISE EXCEPTION 'O seu perfil (%) não tem permissão para esta operação.', v_role;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Colunas adicionais exigidas pelos módulos (recibo, PDV, entregas, caixa)
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS session_id TEXT;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS receipt_number TEXT;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS customer_name TEXT;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS cashier_name TEXT;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS payment_details JSONB DEFAULT '{}'::JSONB;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS total_cogs NUMERIC(14, 4) DEFAULT 0;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS gross_profit NUMERIC(12, 2) DEFAULT 0;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS needs_delivery BOOLEAN DEFAULT FALSE;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS reversal_reason TEXT;
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS reversed_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS product_name TEXT;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS product_code TEXT;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS batch_id TEXT;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS batch_number TEXT;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS packaging_name TEXT;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS quantity_base NUMERIC(12, 3);
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS multiplier_to_base NUMERIC(12, 4) DEFAULT 1;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS unit_cogs NUMERIC(12, 4) DEFAULT 0;
ALTER TABLE public.sale_items ADD COLUMN IF NOT EXISTS total_cogs NUMERIC(14, 4) DEFAULT 0;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS sale_number TEXT;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS contact_phone TEXT;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS items JSONB DEFAULT '[]'::JSONB;
ALTER TABLE public.cash_sessions ADD COLUMN IF NOT EXISTS cashier_name TEXT;
ALTER TABLE public.product_packages ADD COLUMN IF NOT EXISTS sale_price NUMERIC(12, 2);
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS receipt_width TEXT DEFAULT '80mm';
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS scale_protocol TEXT;
ALTER TABLE public.stores ADD COLUMN IF NOT EXISTS receipt_footer TEXT;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS quote_number TEXT;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS discount NUMERIC(12, 2) DEFAULT 0;
ALTER TABLE public.quotes ADD COLUMN IF NOT EXISTS project_location TEXT;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS vehicle_plate TEXT;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS dispatched_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.losses ADD COLUMN IF NOT EXISTS product_name TEXT;
ALTER TABLE public.losses ADD COLUMN IF NOT EXISTS unit TEXT;
ALTER TABLE public.losses ADD COLUMN IF NOT EXISTS cost_unit NUMERIC(12, 4) DEFAULT 0;
ALTER TABLE public.losses ADD COLUMN IF NOT EXISTS notes TEXT;
ALTER TABLE public.losses ADD COLUMN IF NOT EXISTS user_name TEXT;
ALTER TABLE public.inventories ADD COLUMN IF NOT EXISTS operator_name TEXT;

-- Venda atômica com baixa FEFO por lote, atualização de caixa, crédito (fiado) e auditoria
-- numa única transação. Qualquer erro reverte tudo (nenhuma gravação parcial).
CREATE OR REPLACE FUNCTION public.fn_process_atomic_sale(
    p_store_id TEXT,
    p_session_id TEXT,
    p_customer_id TEXT,
    p_customer_name TEXT,
    p_payment_method TEXT,
    p_discount NUMERIC,
    p_items JSONB, -- [{productId, quantity, unitPrice, multiplierToBase, packagingName}]
    p_operator_id UUID,
    p_notes TEXT DEFAULT NULL,
    p_cashier_name TEXT DEFAULT NULL,
    p_payment_details JSONB DEFAULT '{}'::JSONB,
    p_needs_delivery BOOLEAN DEFAULT FALSE
) RETURNS public.sales AS $$
DECLARE
    v_sale public.sales;
    v_sale_id TEXT;
    v_item JSONB;
    v_product RECORD;
    v_batch RECORD;
    v_customer RECORD;
    v_qty_needed NUMERIC;
    v_qty_from_batch NUMERIC;
    v_mult NUMERIC;
    v_price NUMERIC;
    v_total_gross NUMERIC := 0;
    v_total_net NUMERIC;
    v_total_cogs NUMERIC := 0;
    v_seq INT;
    v_code TEXT;
    v_receipt TEXT;
    v_pack TEXT;
BEGIN
    p_operator_id := auth.uid();
    PERFORM public.fn_assert_store_access(p_store_id);
    IF public.get_auth_user_role() <> 'SUPERADMIN' THEN
        IF p_store_id <> public.get_auth_user_store_id() THEN
            RAISE EXCEPTION 'Sem permissão para vender nesta loja.';
        END IF;
        IF NOT public.fn_is_store_unlocked(p_store_id) THEN
            RAISE EXCEPTION 'Assinatura da loja vencida. Regularize para continuar vendendo.';
        END IF;
    END IF;

    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'A venda não possui itens.';
    END IF;

    IF p_payment_method IN ('FIADO', 'CREDITO_FIADO') THEN
        IF p_customer_id IS NULL THEN
            RAISE EXCEPTION 'Venda a crédito exige um cliente cadastrado.';
        END IF;
    END IF;

    -- 1. Validação prévia de estoque (com bloqueio de linha contra vendas concorrentes)
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        SELECT * INTO v_product FROM public.products
        WHERE id = (v_item->>'productId') AND store_id = p_store_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Produto não encontrado nesta loja: %', (v_item->>'productId');
        END IF;
        IF (v_item->>'quantity')::NUMERIC <= 0 THEN
            RAISE EXCEPTION 'Quantidade inválida para "%".', v_product.name;
        END IF;
        v_mult := COALESCE(NULLIF((v_item->>'multiplierToBase')::NUMERIC, 0), 1);
        v_qty_needed := (v_item->>'quantity')::NUMERIC * v_mult;
        IF v_product.current_stock < v_qty_needed THEN
            RAISE EXCEPTION 'Estoque insuficiente para "%". Disponível: % %, Solicitado: %', v_product.name, v_product.current_stock, v_product.unit, v_qty_needed;
        END IF;
        v_total_gross := v_total_gross + round((v_item->>'quantity')::NUMERIC * (v_item->>'unitPrice')::NUMERIC, 2);
    END LOOP;

    v_total_net := GREATEST(0, v_total_gross - COALESCE(p_discount, 0));

    IF p_payment_method IN ('FIADO', 'CREDITO_FIADO') THEN
        SELECT * INTO v_customer FROM public.customers WHERE id = p_customer_id AND store_id = p_store_id FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Cliente não encontrado nesta loja.'; END IF;
        IF v_customer.current_debt + v_total_net > v_customer.credit_limit THEN
            RAISE EXCEPTION 'Limite de crédito excedido. Disponível: %', (v_customer.credit_limit - v_customer.current_debt);
        END IF;
    END IF;

    SELECT COUNT(*) + 1001 INTO v_seq FROM public.sales WHERE store_id = p_store_id;
    v_code := 'VEN-' || v_seq;
    v_receipt := 'REC-' || to_char(now(), 'YYYYMMDD') || '-' || floor(random() * 900000 + 100000)::INT;
    v_sale_id := 'sale-' || extract(epoch FROM clock_timestamp())::BIGINT || '-' || floor(random() * 900000 + 100000)::INT;

    INSERT INTO public.sales (id, store_id, code, receipt_number, session_id, customer_id, customer_name, operator_id, cashier_name,
                              total_gross, discount, total_net, payment_method, payment_details, needs_delivery, status, notes)
    VALUES (v_sale_id, p_store_id, v_code, v_receipt, p_session_id, p_customer_id, p_customer_name, p_operator_id, p_cashier_name,
            v_total_gross, COALESCE(p_discount, 0), v_total_net, p_payment_method, COALESCE(p_payment_details, '{}'::JSONB), COALESCE(p_needs_delivery, FALSE), 'CONCLUIDA', p_notes);

    -- 2. Baixa FEFO por lote, itens da venda e kardex
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        SELECT * INTO v_product FROM public.products WHERE id = (v_item->>'productId') FOR UPDATE;
        v_mult := COALESCE(NULLIF((v_item->>'multiplierToBase')::NUMERIC, 0), 1);
        v_price := (v_item->>'unitPrice')::NUMERIC;
        v_pack := COALESCE(v_item->>'packagingName', v_product.unit);
        v_qty_needed := (v_item->>'quantity')::NUMERIC * v_mult;

        FOR v_batch IN
            SELECT * FROM public.batches
            WHERE product_id = v_product.id AND status = 'ACTIVE' AND current_quantity_base > 0
            ORDER BY expiry_date ASC NULLS LAST
            FOR UPDATE
        LOOP
            EXIT WHEN v_qty_needed <= 0;
            v_qty_from_batch := LEAST(v_batch.current_quantity_base, v_qty_needed);

            UPDATE public.batches
            SET current_quantity_base = current_quantity_base - v_qty_from_batch,
                status = CASE WHEN current_quantity_base - v_qty_from_batch <= 0 THEN 'EXHAUSTED' ELSE 'ACTIVE' END
            WHERE id = v_batch.id;

            INSERT INTO public.sale_items (sale_id, product_id, product_name, product_code, batch_id, batch_number, packaging_name,
                                           quantity, quantity_base, multiplier_to_base, unit_price, total_price, unit_cogs, total_cogs, location)
            VALUES (v_sale_id, v_product.id, v_product.name, v_product.code, v_batch.id, v_batch.batch_number, v_pack,
                    v_qty_from_batch / v_mult, v_qty_from_batch, v_mult, v_price, round((v_qty_from_batch / v_mult) * v_price, 2),
                    v_batch.cost_per_base, v_qty_from_batch * v_batch.cost_per_base, 'LOJA');

            INSERT INTO public.stock_movements (id, store_id, product_id, batch_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
            VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, v_product.id, v_batch.id, 'SAIDA_VENDA', -v_qty_from_batch, 'LOJA', 'sales', v_sale_id, p_operator_id);

            v_total_cogs := v_total_cogs + (v_qty_from_batch * v_batch.cost_per_base);
            v_qty_needed := v_qty_needed - v_qty_from_batch;
        END LOOP;

        IF v_qty_needed > 0 THEN
            -- Produto sem lote suficiente cadastrado: baixa direta ao custo do produto
            INSERT INTO public.sale_items (sale_id, product_id, product_name, product_code, packaging_name,
                                           quantity, quantity_base, multiplier_to_base, unit_price, total_price, unit_cogs, total_cogs, location)
            VALUES (v_sale_id, v_product.id, v_product.name, v_product.code, v_pack,
                    v_qty_needed / v_mult, v_qty_needed, v_mult, v_price, round((v_qty_needed / v_mult) * v_price, 2),
                    v_product.cost_price, v_qty_needed * v_product.cost_price, 'LOJA');

            INSERT INTO public.stock_movements (id, store_id, product_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
            VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, v_product.id, 'SAIDA_VENDA', -v_qty_needed, 'LOJA', 'sales', v_sale_id, p_operator_id);

            v_total_cogs := v_total_cogs + (v_qty_needed * v_product.cost_price);
        END IF;

        UPDATE public.products
        SET current_stock = current_stock - ((v_item->>'quantity')::NUMERIC * v_mult),
            stock_loja = GREATEST(0, stock_loja - ((v_item->>'quantity')::NUMERIC * v_mult))
        WHERE id = v_product.id;
    END LOOP;

    UPDATE public.sales SET total_cogs = v_total_cogs, gross_profit = v_total_net - v_total_cogs WHERE id = v_sale_id;

    -- 3. Crédito/fiado
    IF p_payment_method IN ('FIADO', 'CREDITO_FIADO') THEN
        UPDATE public.customers SET current_debt = current_debt + v_total_net WHERE id = p_customer_id;
        INSERT INTO public.credit_transactions (id, customer_id, type, amount, balance_after, notes, operator_id)
        SELECT 'ctx-' || gen_random_uuid()::TEXT, p_customer_id, 'DEBITO_VENDA', v_total_net, current_debt, 'Compra a fiado na venda ' || v_code, p_operator_id
        FROM public.customers WHERE id = p_customer_id;
    END IF;

    -- 4. Movimento de caixa (exige sessão aberta da mesma loja quando informada)
    IF p_session_id IS NOT NULL THEN
        PERFORM 1 FROM public.cash_sessions WHERE id = p_session_id AND store_id = p_store_id AND is_closed = FALSE FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'A sessão de caixa informada não está aberta.';
        END IF;
        INSERT INTO public.cash_movements (id, store_id, session_id, movement_type, payment_method, amount, reason, operator_id)
        VALUES ('mov-sale-' || gen_random_uuid()::TEXT, p_store_id, p_session_id, 'SALE', p_payment_method, v_total_net, 'Venda ' || v_receipt, p_operator_id);
    END IF;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, p_store_id, 'VENDA', 'sales', v_sale_id,
            'Venda ' || v_code || ' (' || v_receipt || ') total ' || v_total_net || ' via ' || p_payment_method, p_operator_id);

    SELECT * INTO v_sale FROM public.sales WHERE id = v_sale_id;
    RETURN v_sale;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Estorno atômico: repõe estoque, lotes, fiado e caixa a partir do kardex real da venda.
CREATE OR REPLACE FUNCTION public.fn_reverse_sale(p_sale_id TEXT, p_reason TEXT, p_operator_id UUID)
RETURNS public.sales AS $$
DECLARE
    v_sale public.sales;
    v_mov RECORD;
BEGIN
    p_operator_id := auth.uid();
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'Informe o motivo do estorno.';
    END IF;

    SELECT * INTO v_sale FROM public.sales WHERE id = p_sale_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Venda não encontrada.'; END IF;
    IF public.get_auth_user_role() NOT IN ('SUPERADMIN') AND v_sale.store_id <> public.get_auth_user_store_id() THEN
        RAISE EXCEPTION 'Sem permissão para estornar vendas desta loja.';
    END IF;
    IF public.get_auth_user_role() NOT IN ('SUPERADMIN', 'ADMIN', 'GERENTE') THEN
        RAISE EXCEPTION 'Apenas ADMIN ou GERENTE podem estornar vendas.';
    END IF;
    IF v_sale.status = 'CANCELADA' THEN RAISE EXCEPTION 'Esta venda já foi estornada anteriormente.'; END IF;

    FOR v_mov IN SELECT * FROM public.stock_movements
                 WHERE reference_type = 'sales' AND reference_id = p_sale_id AND movement_type = 'SAIDA_VENDA' LOOP
        UPDATE public.products
        SET current_stock = current_stock - v_mov.quantity_base,
            stock_loja = stock_loja - v_mov.quantity_base
        WHERE id = v_mov.product_id;

        IF v_mov.batch_id IS NOT NULL THEN
            UPDATE public.batches
            SET current_quantity_base = current_quantity_base - v_mov.quantity_base, status = 'ACTIVE'
            WHERE id = v_mov.batch_id;
        END IF;

        INSERT INTO public.stock_movements (id, store_id, product_id, batch_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
        VALUES ('mov-' || gen_random_uuid()::TEXT, v_mov.store_id, v_mov.product_id, v_mov.batch_id, 'ESTORNO_VENDA', -v_mov.quantity_base, v_mov.location, 'sales', p_sale_id, p_operator_id);
    END LOOP;

    IF v_sale.payment_method IN ('FIADO', 'CREDITO_FIADO') AND v_sale.customer_id IS NOT NULL THEN
        UPDATE public.customers SET current_debt = GREATEST(0, current_debt - v_sale.total_net) WHERE id = v_sale.customer_id;
        INSERT INTO public.credit_transactions (id, customer_id, type, amount, balance_after, notes, operator_id)
        SELECT 'ctx-' || gen_random_uuid()::TEXT, v_sale.customer_id, 'ESTORNO', v_sale.total_net, current_debt, 'Estorno da venda ' || v_sale.code, p_operator_id
        FROM public.customers WHERE id = v_sale.customer_id;
    END IF;

    IF v_sale.session_id IS NOT NULL THEN
        INSERT INTO public.cash_movements (id, store_id, session_id, movement_type, payment_method, amount, reason, operator_id)
        SELECT 'mov-est-' || gen_random_uuid()::TEXT, v_sale.store_id, v_sale.session_id, 'ESTORNO', v_sale.payment_method, v_sale.total_net, 'Estorno da venda ' || v_sale.code, p_operator_id
        WHERE EXISTS (SELECT 1 FROM public.cash_sessions cs WHERE cs.id = v_sale.session_id AND cs.is_closed = FALSE);
    END IF;

    UPDATE public.sales SET status = 'CANCELADA', reversal_reason = p_reason, reversed_at = NOW()
    WHERE id = p_sale_id RETURNING * INTO v_sale;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, v_sale.store_id, 'ESTORNO_VENDA', 'sales', p_sale_id,
            'Estorno da venda ' || v_sale.code || '. Motivo: ' || p_reason, p_operator_id);

    RETURN v_sale;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fechamento de caixa: o saldo esperado é calculado no banco a partir dos movimentos reais.
-- esperado = fundo inicial + vendas em dinheiro + reforços - sangrias - despesas - estornos em dinheiro
CREATE OR REPLACE FUNCTION public.fn_close_cash_session(p_session_id TEXT, p_counted_cash NUMERIC, p_notes TEXT, p_operator_id UUID)
RETURNS public.cash_sessions AS $$
DECLARE
    v_session public.cash_sessions;
    v_expected NUMERIC;
BEGIN
    p_operator_id := auth.uid();
    SELECT * INTO v_session FROM public.cash_sessions WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sessão de caixa não encontrada.'; END IF;
    IF public.get_auth_user_role() <> 'SUPERADMIN' AND v_session.store_id <> public.get_auth_user_store_id() THEN
        RAISE EXCEPTION 'Sem permissão para fechar o caixa desta loja.';
    END IF;
    IF v_session.is_closed THEN RAISE EXCEPTION 'Sessão já está fechada.'; END IF;

    SELECT v_session.opening_balance + COALESCE(SUM(
        CASE
            WHEN cm.movement_type = 'SALE' AND cm.payment_method IN ('DINHEIRO', 'CASH') THEN cm.amount
            WHEN cm.movement_type = 'REFORCO' THEN cm.amount
            WHEN cm.movement_type IN ('SANGRIA_BANK', 'SANGRIA_SAFE', 'DESPESA') THEN -cm.amount
            WHEN cm.movement_type = 'ESTORNO' AND cm.payment_method IN ('DINHEIRO', 'CASH') THEN -cm.amount
            ELSE 0
        END
    ), 0) INTO v_expected
    FROM public.cash_movements cm WHERE cm.session_id = p_session_id;

    UPDATE public.cash_sessions
    SET closed_at = NOW(), declared_cash = p_counted_cash, expected_cash = v_expected,
        difference = p_counted_cash - v_expected, is_closed = TRUE, notes = p_notes
    WHERE id = p_session_id
    RETURNING * INTO v_session;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, v_session.store_id, 'FECHAMENTO_CAIXA', 'cash_sessions', p_session_id,
            'Fechamento. Esperado: ' || v_expected || ', Contado: ' || p_counted_cash || ', Diferença: ' || (p_counted_cash - v_expected), p_operator_id);

    RETURN v_session;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==============================================================================
-- 22. DESBLOQUEIO DE ASSINATURA: SEM CÓDIGO MESTRE FIXO NO CLIENTE.
-- Regra 39/45: nada de senha hardcoded no JS. Só SUPERADMIN pode chamar isto,
-- e a policy de stores já garante isso -- aqui é só uma RPC de conveniência
-- que reforça a mesma checagem no backend.
-- ==============================================================================
CREATE OR REPLACE FUNCTION public.fn_renew_store_subscription(p_store_id TEXT, p_days INT DEFAULT 30)
RETURNS public.stores AS $$
DECLARE
    v_store public.stores;
BEGIN
    IF public.get_auth_user_role() <> 'SUPERADMIN' THEN
        RAISE EXCEPTION 'Apenas o Superadmin pode renovar assinaturas de lojas.';
    END IF;

    UPDATE public.stores
    SET data_fim_teste = GREATEST(data_fim_teste, CURRENT_DATE) + (p_days || ' days')::INTERVAL,
        acesso_ativo = TRUE,
        motivo_bloqueio = NULL
    WHERE id = p_store_id
    RETURNING * INTO v_store;

    IF NOT FOUND THEN RAISE EXCEPTION 'Loja não encontrada.'; END IF;
    RETURN v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Confirmação de compra: entrada de estoque + custo médio ponderado + lote (se houver) -- atômico.
CREATE OR REPLACE FUNCTION public.fn_confirm_purchase(
    p_store_id TEXT,
    p_supplier_id TEXT,
    p_supplier_name TEXT,
    p_invoice_number TEXT,
    p_destination_location TEXT,
    p_items JSONB, -- [{productId, quantityPurchased, unitCost, newSalePrice, batchNumber, expiryDate}]
    p_operator_id UUID,
    p_notes TEXT DEFAULT NULL
) RETURNS public.purchases AS $$
DECLARE
    v_purchase public.purchases;
    v_purchase_id TEXT;
    v_item JSONB;
    v_product RECORD;
    v_qty NUMERIC;
    v_total_cost NUMERIC := 0;
    v_new_stock NUMERIC;
    v_new_cost NUMERIC;
    v_batch_id TEXT;
BEGIN
    p_operator_id := auth.uid();
    PERFORM public.fn_assert_store_access(p_store_id, ARRAY['ADMIN','GERENTE','ESTOQUISTA']);
    v_purchase_id := 'purch-' || extract(epoch FROM now())::BIGINT || '-' || floor(random() * 9000 + 1000)::TEXT;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_total_cost := v_total_cost + ((v_item->>'quantityPurchased')::NUMERIC * COALESCE((v_item->>'unitCost')::NUMERIC, 0));
    END LOOP;

    INSERT INTO public.purchases (id, store_id, supplier_id, supplier_name, invoice_number, destination_location, total_cost, notes, operator_id)
    VALUES (v_purchase_id, p_store_id, p_supplier_id, p_supplier_name, p_invoice_number, COALESCE(p_destination_location, 'ARMAZEM'), v_total_cost, p_notes, p_operator_id)
    RETURNING * INTO v_purchase;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        SELECT * INTO v_product FROM public.products WHERE id = (v_item->>'productId') FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Produto não encontrado: %', (v_item->>'productId');
        END IF;

        v_qty := (v_item->>'quantityPurchased')::NUMERIC;
        v_new_stock := v_product.current_stock + v_qty;

        -- Custo médio ponderado
        IF (v_item->>'unitCost') IS NOT NULL AND (v_item->>'unitCost')::NUMERIC > 0 AND v_new_stock > 0 THEN
            v_new_cost := ((v_product.current_stock * v_product.cost_price) + (v_qty * (v_item->>'unitCost')::NUMERIC)) / v_new_stock;
        ELSE
            v_new_cost := v_product.cost_price;
        END IF;

        UPDATE public.products SET
            current_stock = v_new_stock,
            cost_price = v_new_cost,
            sale_price = COALESCE((v_item->>'newSalePrice')::NUMERIC, sale_price),
            stock_loja = CASE WHEN COALESCE(p_destination_location, 'ARMAZEM') = 'LOJA' THEN stock_loja + v_qty ELSE stock_loja END,
            stock_armazem = CASE WHEN COALESCE(p_destination_location, 'ARMAZEM') = 'ARMAZEM' THEN stock_armazem + v_qty ELSE stock_armazem END,
            stock_patio = CASE WHEN COALESCE(p_destination_location, 'ARMAZEM') = 'PATIO' THEN stock_patio + v_qty ELSE stock_patio END
        WHERE id = v_product.id;

        INSERT INTO public.purchase_items (purchase_id, product_id, quantity_purchased, unit_cost, new_sale_price, batch_number, expiry_date)
        VALUES (v_purchase_id, v_product.id, v_qty, COALESCE((v_item->>'unitCost')::NUMERIC, 0), (v_item->>'newSalePrice')::NUMERIC, v_item->>'batchNumber', (v_item->>'expiryDate')::DATE);

        v_batch_id := NULL;
        IF v_item->>'batchNumber' IS NOT NULL AND TRIM(v_item->>'batchNumber') <> '' THEN
            v_batch_id := 'batch-' || gen_random_uuid()::TEXT;
            INSERT INTO public.batches (id, store_id, product_id, batch_number, supplier_id, initial_quantity_base, current_quantity_base, cost_per_base, expiry_date, status)
            VALUES (v_batch_id, p_store_id, v_product.id, v_item->>'batchNumber', p_supplier_id, v_qty, v_qty, COALESCE((v_item->>'unitCost')::NUMERIC, v_new_cost), (v_item->>'expiryDate')::DATE, 'ACTIVE');
        END IF;

        INSERT INTO public.stock_movements (id, store_id, product_id, batch_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
        VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, v_product.id, v_batch_id, 'ENTRADA_COMPRA', v_qty, COALESCE(p_destination_location, 'ARMAZEM'), 'purchases', v_purchase_id, p_operator_id);
    END LOOP;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, p_store_id, 'ENTRADA_COMPRA', 'purchases', v_purchase_id, 'Compra NF ' || COALESCE(p_invoice_number,'-') || ' de ' || COALESCE(p_supplier_name,'-') || ' total ' || v_total_cost, p_operator_id);

    RETURN v_purchase;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Transferência interna atômica entre localizações (LOJA/ARMAZEM/PATIO)
CREATE OR REPLACE FUNCTION public.fn_transfer_stock(
    p_store_id TEXT, p_product_id TEXT, p_quantity_base NUMERIC,
    p_from_location TEXT, p_to_location TEXT, p_operator_id UUID, p_notes TEXT DEFAULT NULL
) RETURNS public.transfers AS $$
DECLARE
    v_transfer public.transfers;
    v_transfer_id TEXT;
    v_product RECORD;
    v_from_col TEXT;
    v_to_col TEXT;
    v_current_from NUMERIC;
BEGIN
    p_operator_id := auth.uid();
    PERFORM public.fn_assert_store_access(p_store_id, ARRAY['ADMIN','GERENTE','ESTOQUISTA']);
    IF p_from_location = p_to_location THEN
        RAISE EXCEPTION 'Origem e destino não podem ser iguais.';
    END IF;

    SELECT * INTO v_product FROM public.products WHERE id = p_product_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado.'; END IF;

    v_from_col := CASE p_from_location WHEN 'LOJA' THEN 'stock_loja' WHEN 'ARMAZEM' THEN 'stock_armazem' WHEN 'PATIO' THEN 'stock_patio' END;
    v_to_col := CASE p_to_location WHEN 'LOJA' THEN 'stock_loja' WHEN 'ARMAZEM' THEN 'stock_armazem' WHEN 'PATIO' THEN 'stock_patio' END;

    EXECUTE format('SELECT %I FROM public.products WHERE id = $1', v_from_col) INTO v_current_from USING p_product_id;
    IF v_current_from < p_quantity_base THEN
        RAISE EXCEPTION 'Estoque insuficiente em %% para transferência.', p_from_location;
    END IF;

    EXECUTE format('UPDATE public.products SET %I = %I - $1, %I = %I + $1 WHERE id = $2', v_from_col, v_from_col, v_to_col, v_to_col)
    USING p_quantity_base, p_product_id;

    v_transfer_id := 'transf-' || extract(epoch FROM now())::BIGINT || '-' || floor(random() * 9000 + 1000)::TEXT;
    INSERT INTO public.transfers (id, store_id, product_id, quantity_base, from_location, to_location, operator_id, notes)
    VALUES (v_transfer_id, p_store_id, p_product_id, p_quantity_base, p_from_location, p_to_location, p_operator_id, p_notes)
    RETURNING * INTO v_transfer;

    INSERT INTO public.stock_movements (id, store_id, product_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
    VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, p_product_id, 'TRANSFERENCIA', p_quantity_base, p_to_location, 'transfers', v_transfer_id, p_operator_id);

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, p_store_id, 'TRANSFERENCIA', 'transfers', v_transfer_id,
        'Transferência de ' || p_quantity_base || ' de ' || p_from_location || ' para ' || p_to_location, p_operator_id);

    RETURN v_transfer;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Registro de perda/avaria atômico
CREATE OR REPLACE FUNCTION public.fn_register_loss(
    p_store_id TEXT, p_product_id TEXT, p_quantity_base NUMERIC,
    p_location TEXT, p_reason TEXT, p_operator_id UUID, p_notes TEXT DEFAULT NULL
) RETURNS public.losses AS $$
DECLARE
    v_loss public.losses;
    v_loss_id TEXT;
    v_product RECORD;
    v_loc TEXT := COALESCE(p_location, 'LOJA');
    v_current NUMERIC;
    v_total_cost NUMERIC;
    v_user_name TEXT;
BEGIN
    p_operator_id := auth.uid();
    PERFORM public.fn_assert_store_access(p_store_id, ARRAY['ADMIN','GERENTE','ESTOQUISTA']);
    IF p_quantity_base IS NULL OR p_quantity_base <= 0 THEN RAISE EXCEPTION 'A quantidade deve ser maior que zero.'; END IF;
    IF v_loc NOT IN ('LOJA', 'ARMAZEM', 'PATIO') THEN RAISE EXCEPTION 'Localização inválida.'; END IF;

    SELECT * INTO v_product FROM public.products WHERE id = p_product_id AND store_id = p_store_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado nesta loja.'; END IF;

    v_current := CASE v_loc WHEN 'LOJA' THEN v_product.stock_loja WHEN 'ARMAZEM' THEN v_product.stock_armazem ELSE v_product.stock_patio END;
    IF v_current < p_quantity_base THEN
        RAISE EXCEPTION 'Estoque insuficiente em % para registrar a perda (disponível: %).', v_loc, v_current;
    END IF;

    v_total_cost := p_quantity_base * v_product.cost_price;
    SELECT full_name INTO v_user_name FROM public.profiles WHERE id = p_operator_id;

    UPDATE public.products SET
        current_stock = current_stock - p_quantity_base,
        stock_loja = CASE WHEN v_loc = 'LOJA' THEN stock_loja - p_quantity_base ELSE stock_loja END,
        stock_armazem = CASE WHEN v_loc = 'ARMAZEM' THEN stock_armazem - p_quantity_base ELSE stock_armazem END,
        stock_patio = CASE WHEN v_loc = 'PATIO' THEN stock_patio - p_quantity_base ELSE stock_patio END
    WHERE id = p_product_id;

    v_loss_id := 'loss-' || extract(epoch FROM clock_timestamp())::BIGINT || '-' || floor(random() * 9000 + 1000)::INT;
    INSERT INTO public.losses (id, store_id, product_id, product_name, unit, cost_unit, quantity_base, location, reason, notes, total_loss_cost, operator_id, user_name)
    VALUES (v_loss_id, p_store_id, p_product_id, v_product.name, v_product.unit, v_product.cost_price, p_quantity_base, v_loc, p_reason, p_notes, v_total_cost, p_operator_id, v_user_name)
    RETURNING * INTO v_loss;

    INSERT INTO public.stock_movements (id, store_id, product_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
    VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, p_product_id, 'PERDA', -p_quantity_base, v_loc, 'losses', v_loss_id, p_operator_id);

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, p_store_id, 'PERDA_REGISTRADA', 'losses', v_loss_id,
        'Baixa de ' || p_quantity_base || ' ' || v_product.unit || ' de ' || v_product.name || ' (' || p_reason || '). Prejuízo: ' || v_total_cost, p_operator_id);

    RETURN v_loss;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Recebimento de dívida (fiado) atômico; se em dinheiro e houver turno aberto, entra no caixa (REFORCO).
CREATE OR REPLACE FUNCTION public.fn_register_customer_payment(
    p_customer_id TEXT, p_amount NUMERIC, p_notes TEXT, p_operator_id UUID,
    p_payment_method TEXT DEFAULT 'DINHEIRO', p_session_id TEXT DEFAULT NULL
) RETURNS public.customers AS $$
DECLARE
    v_customer public.customers;
BEGIN
    p_operator_id := auth.uid();
    SELECT * INTO v_customer FROM public.customers WHERE id = p_customer_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Cliente não encontrado.'; END IF;
    PERFORM public.fn_assert_store_access(v_customer.store_id);
    IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'O valor do pagamento deve ser maior que zero.'; END IF;
    IF p_amount > v_customer.current_debt THEN RAISE EXCEPTION 'O valor excede a dívida atual (%).', v_customer.current_debt; END IF;

    UPDATE public.customers SET current_debt = current_debt - p_amount WHERE id = p_customer_id
    RETURNING * INTO v_customer;

    INSERT INTO public.credit_transactions (id, customer_id, type, amount, balance_after, notes, operator_id)
    VALUES ('ctx-' || gen_random_uuid()::TEXT, p_customer_id, 'PAGAMENTO', p_amount, v_customer.current_debt,
            COALESCE(p_notes, 'Pagamento de conta') || ' (' || COALESCE(p_payment_method, 'DINHEIRO') || ')', p_operator_id);

    IF p_payment_method = 'DINHEIRO' AND p_session_id IS NOT NULL THEN
        PERFORM 1 FROM public.cash_sessions WHERE id = p_session_id AND store_id = v_customer.store_id AND is_closed = FALSE;
        IF FOUND THEN
            INSERT INTO public.cash_movements (id, store_id, session_id, movement_type, payment_method, amount, reason, operator_id)
            VALUES ('mov-' || gen_random_uuid()::TEXT, v_customer.store_id, p_session_id, 'REFORCO', 'DINHEIRO', p_amount,
                    'Recebimento de fiado - ' || v_customer.name, p_operator_id);
        END IF;
    END IF;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, v_customer.store_id, 'RECEBIMENTO_DIVIDA', 'customers', p_customer_id,
        'Recebimento de ' || p_amount || ' de ' || v_customer.name || ' via ' || COALESCE(p_payment_method, 'DINHEIRO'), p_operator_id);

    RETURN v_customer;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Reconciliação de inventário físico (confrontação de estoque) atômica
CREATE OR REPLACE FUNCTION public.fn_reconcile_inventory(
    p_store_id TEXT, p_items JSONB, p_notes TEXT, p_reconcile BOOLEAN, p_operator_id UUID
) RETURNS public.inventories AS $$
DECLARE
    v_inventory public.inventories;
    v_inventory_id TEXT;
    v_item JSONB;
    v_product RECORD;
    v_diff NUMERIC;
    v_total_divergent INT := 0;
    v_total_diff_value NUMERIC := 0;
    v_audited_items JSONB := '[]'::JSONB;
BEGIN
    p_operator_id := auth.uid();
    PERFORM public.fn_assert_store_access(p_store_id, ARRAY['ADMIN','GERENTE','ESTOQUISTA']);
    v_inventory_id := 'inv-' || extract(epoch FROM now())::BIGINT;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        SELECT * INTO v_product FROM public.products WHERE id = (v_item->>'productId') FOR UPDATE;
        IF NOT FOUND THEN CONTINUE; END IF;

        v_diff := (v_item->>'physicalStock')::NUMERIC - v_product.current_stock;
        IF v_diff <> 0 THEN
            v_total_divergent := v_total_divergent + 1;
            v_total_diff_value := v_total_diff_value + (v_diff * v_product.cost_price);
        END IF;

        v_audited_items := v_audited_items || jsonb_build_object(
            'productId', v_product.id, 'productName', v_product.name,
            'systemStock', v_product.current_stock, 'physicalStock', (v_item->>'physicalStock')::NUMERIC,
            'divergence', v_diff, 'unitCost', v_product.cost_price, 'diffValue', v_diff * v_product.cost_price
        );

        IF p_reconcile THEN
            UPDATE public.products SET current_stock = (v_item->>'physicalStock')::NUMERIC WHERE id = v_product.id;
            INSERT INTO public.stock_movements (id, store_id, product_id, movement_type, quantity_base, location, reference_type, reference_id, operator_id)
            VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, v_product.id, 'AJUSTE_INVENTARIO', v_diff, COALESCE(v_item->>'location', 'LOJA'), 'inventories', v_inventory_id, p_operator_id);
        END IF;
    END LOOP;

    INSERT INTO public.inventories (id, store_id, code, operator_id, operator_name, reconciled, notes, total_items_audited, total_divergent_items, total_divergence_value, items)
    VALUES (v_inventory_id, p_store_id, 'INV-' || to_char(now(), 'YYYYMMDDHH24MISS'), p_operator_id, (SELECT full_name FROM public.profiles WHERE id = p_operator_id), p_reconcile, p_notes, jsonb_array_length(p_items), v_total_divergent, v_total_diff_value, v_audited_items)
    RETURNING * INTO v_inventory;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, p_store_id, CASE WHEN p_reconcile THEN 'INVENTARIO_CONCILIADO' ELSE 'INVENTARIO_CONFRONTACAO' END,
        'inventories', v_inventory_id, v_total_divergent || ' itens divergentes, impacto ' || v_total_diff_value, p_operator_id);

    RETURN v_inventory;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ==============================================================================
-- 23. RPCs DE CAIXA: ABERTURA, SANGRIA, REFORÇO (SUPRIMENTO) E DESPESA
-- Auditoria só é gravada dentro de RPCs (audit_logs não aceita INSERT direto do cliente).
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.fn_open_cash_session(p_store_id TEXT, p_initial_cash NUMERIC, p_cashier_name TEXT)
RETURNS public.cash_sessions AS $$
DECLARE
    v_session public.cash_sessions;
    v_id TEXT;
BEGIN
    PERFORM public.fn_assert_store_access(p_store_id);
    IF p_initial_cash IS NULL OR p_initial_cash < 0 THEN
        RAISE EXCEPTION 'O fundo de troco inicial não pode ser negativo.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cash_sessions WHERE store_id = p_store_id AND is_closed = FALSE) THEN
        RAISE EXCEPTION 'Já existe um turno de caixa aberto nesta loja. Feche-o antes de abrir outro.';
    END IF;

    v_id := 'session-' || extract(epoch FROM clock_timestamp())::BIGINT || '-' || floor(random() * 9000 + 1000)::INT;
    INSERT INTO public.cash_sessions (id, store_id, operator_id, cashier_name, opening_balance, expected_cash, is_closed)
    VALUES (v_id, p_store_id, auth.uid(), p_cashier_name, p_initial_cash, p_initial_cash, FALSE)
    RETURNING * INTO v_session;

    INSERT INTO public.cash_movements (id, store_id, session_id, movement_type, payment_method, amount, reason, operator_id)
    VALUES ('mov-' || gen_random_uuid()::TEXT, p_store_id, v_id, 'INITIAL', 'DINHEIRO', p_initial_cash, 'Abertura de turno (fundo de troco)', auth.uid());

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, p_store_id, 'ABERTURA_CAIXA', 'cash_sessions', v_id,
            'Abertura de caixa com fundo de ' || p_initial_cash, auth.uid());

    RETURN v_session;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.fn_register_cash_movement(
    p_session_id TEXT, p_type TEXT, p_amount NUMERIC, p_reason TEXT, p_notes TEXT DEFAULT NULL
) RETURNS public.cash_movements AS $$
DECLARE
    v_session public.cash_sessions;
    v_mov public.cash_movements;
    v_id TEXT;
    v_cash_now NUMERIC;
BEGIN
    IF p_type NOT IN ('SANGRIA_BANK', 'SANGRIA_SAFE', 'REFORCO', 'DESPESA') THEN
        RAISE EXCEPTION 'Tipo de movimento de caixa inválido: %', p_type;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'O valor deve ser maior que zero.';
    END IF;
    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        RAISE EXCEPTION 'Informe o motivo.';
    END IF;

    SELECT * INTO v_session FROM public.cash_sessions WHERE id = p_session_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Sessão de caixa não encontrada.'; END IF;
    PERFORM public.fn_assert_store_access(v_session.store_id);
    IF v_session.is_closed THEN RAISE EXCEPTION 'O turno de caixa já está fechado.'; END IF;

    IF p_type <> 'REFORCO' THEN
        SELECT v_session.opening_balance + COALESCE(SUM(CASE
            WHEN cm.movement_type = 'SALE' AND cm.payment_method IN ('DINHEIRO', 'CASH') THEN cm.amount
            WHEN cm.movement_type = 'REFORCO' THEN cm.amount
            WHEN cm.movement_type IN ('SANGRIA_BANK', 'SANGRIA_SAFE', 'DESPESA') THEN -cm.amount
            WHEN cm.movement_type = 'ESTORNO' AND cm.payment_method IN ('DINHEIRO', 'CASH') THEN -cm.amount
            ELSE 0 END), 0)
        INTO v_cash_now FROM public.cash_movements cm WHERE cm.session_id = p_session_id;
        IF p_amount > v_cash_now THEN
            RAISE EXCEPTION 'Valor maior que o dinheiro disponível na gaveta (%).', v_cash_now;
        END IF;
    END IF;

    v_id := 'mov-' || gen_random_uuid()::TEXT;
    INSERT INTO public.cash_movements (id, store_id, session_id, movement_type, payment_method, amount, reason, notes, operator_id)
    VALUES (v_id, v_session.store_id, p_session_id, p_type, 'DINHEIRO', p_amount, p_reason, p_notes, auth.uid())
    RETURNING * INTO v_mov;

    IF p_type = 'DESPESA' THEN
        INSERT INTO public.expenses (id, store_id, session_id, category, description, amount, operator_id)
        VALUES ('exp-' || gen_random_uuid()::TEXT, v_session.store_id, p_session_id, 'CAIXA', p_reason, p_amount, auth.uid());
    END IF;

    INSERT INTO public.audit_logs (id, store_id, action, entity, entity_id, details, operator_id)
    VALUES ('audit-' || gen_random_uuid()::TEXT, v_session.store_id, p_type, 'cash_movements', v_id,
            p_type || ' de ' || p_amount || '. Motivo: ' || p_reason, auth.uid());

    RETURN v_mov;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Perfil do próprio usuário: leitura/edição de dados não sensíveis (nome) sem poder mudar role/store/active.
-- (A policy de UPDATE em profiles só permite ADMIN da loja ou SUPERADMIN; o usuário comum não altera o próprio papel.)
