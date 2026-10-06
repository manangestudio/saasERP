-- ==============================================================================
-- GEF | MIGRAÇÃO EMBAIXADORES v4  (idempotente; pode ser executada mais de uma vez)
--
-- Objectivo (e só isto): cada Embaixador ver, de forma ESTÁVEL, todas as lojas que lhe
-- estão vinculadas, com subscrição e comissões.
--
-- Esta versão é AUTOSSUFICIENTE: não depende de a v3 ter corrido bem. Só adiciona.
-- NÃO altera vendas, stock, caixa, PDV, nem o RLS de qualquer outra tabela.
-- NÃO apaga dados. Só preenche store_id onde está vazio.
--
--  1. Garante colunas/tabela de que o painel precisa (ADD ... IF NOT EXISTS).
--  2. Repara o vínculo "loja indicada" -> "loja real" (store_id) em registos antigos.
--  3. Cria fn_ambassador_portal(): UMA chamada SECURITY DEFINER que devolve tudo o que o
--     painel mostra (lojas, subscrição, comissões, liquidações). Não depende de RLS
--     nem de get_auth_user_role(), e cada secção falha de forma isolada (devolve o resto
--     + um aviso), por isso uma falha numa parte nunca esvazia o painel.
--  4. Reafirma as permissões de LEITURA do embaixador sobre os seus dados.
--  5. Liga o Realtime às tabelas do programa (o painel actualiza após cada pagamento).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. COLUNAS / TABELA NECESSÁRIAS (só adições; no-op se a v2 já as criou)
-- ------------------------------------------------------------------------------
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS status TEXT;
ALTER TABLE public.ambassadors ADD COLUMN IF NOT EXISTS pending_commissions NUMERIC(12, 2) DEFAULT 0;
UPDATE public.ambassadors
   SET status = CASE WHEN active = FALSE THEN 'DESATIVADO' ELSE 'ATIVO' END
 WHERE status IS NULL;

ALTER TABLE public.ambassador_referred_stores ADD COLUMN IF NOT EXISTS store_id TEXT;

CREATE TABLE IF NOT EXISTS public.ambassador_commission_payments (
    id TEXT PRIMARY KEY,
    ambassador_id TEXT NOT NULL REFERENCES public.ambassadors(id) ON DELETE CASCADE,
    referred_store_id TEXT,
    store_id TEXT,
    store_name TEXT,
    payment_amount NUMERIC(12, 2) NOT NULL DEFAULT 0,
    commission_rate NUMERIC(5, 2) NOT NULL DEFAULT 0,
    commission_amount NUMERIC(12, 2) NOT NULL DEFAULT 0,
    days_added INT DEFAULT 30,
    paid_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_amb_comm_pay_amb ON public.ambassador_commission_payments(ambassador_id);
ALTER TABLE public.ambassador_commission_payments ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- 2. VÍNCULO LOJA INDICADA -> LOJA REAL
--    Sem este vínculo a loja aparece como "SEM LOJA" e nunca gera comissão quando o
--    Super Admin lança um pagamento.
-- ------------------------------------------------------------------------------

-- 2a. Mesmo id (loja criada pelo painel do embaixador ou pelo link de adesão)
UPDATE public.ambassador_referred_stores r
   SET store_id = r.id
 WHERE r.store_id IS NULL
   AND EXISTS (SELECT 1 FROM public.stores s WHERE s.id = r.id);

-- 2b. Registos antigos com id diferente: liga apenas quando a correspondência é ÚNICA nos
--     dois sentidos (mesmo nome e mesmo telefone). Em caso de dúvida não liga nada.
WITH pares AS (
    SELECT r.id AS referred_id,
           s.id AS store_id,
           COUNT(*) OVER (PARTITION BY r.id) AS lojas_por_registo,
           COUNT(*) OVER (PARTITION BY s.id) AS registos_por_loja
      FROM public.ambassador_referred_stores r
      JOIN public.stores s
        ON LOWER(TRIM(s.name)) = LOWER(TRIM(r.name))
       AND REGEXP_REPLACE(COALESCE(s.phone, ''), '\D', '', 'g')
         = REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g')
       AND REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g') <> ''
     WHERE r.store_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.ambassador_referred_stores x WHERE x.store_id = s.id)
)
UPDATE public.ambassador_referred_stores r
   SET store_id = p.store_id
  FROM pares p
 WHERE r.id = p.referred_id
   AND r.store_id IS NULL
   AND p.lojas_por_registo = 1
   AND p.registos_por_loja = 1;

CREATE INDEX IF NOT EXISTS idx_amb_ref_stores_amb   ON public.ambassador_referred_stores(ambassador_id);
CREATE INDEX IF NOT EXISTS idx_amb_ref_stores_store ON public.ambassador_referred_stores(store_id);

-- ------------------------------------------------------------------------------
-- 3. fn_ambassador_portal(): TUDO O QUE O PAINEL DO EMBAIXADOR MOSTRA, NUMA CHAMADA
--
--  * Embaixador: vê SEMPRE e só o seu próprio registo (liga por ambassadors.user_id).
--  * Super Admin: pode passar p_ambassador_id para pré-visualizar um embaixador.
--  * Só devolve subscrição/comissão/liquidações. Nada de vendas, stock, compras, caixa.
--  * SECURITY DEFINER: lê as tabelas directamente (não depende de policies RLS nem de
--    get_auth_user_role()); a autorização é feita aqui dentro.
--  * Cada secção está isolada: se uma falhar, o resto é devolvido e o motivo vai em "warnings".
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.fn_ambassador_portal(TEXT);
CREATE OR REPLACE FUNCTION public.fn_ambassador_portal(p_ambassador_id TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_uid        UUID := auth.uid();
    v_role       TEXT;
    v_amb        public.ambassadors%ROWTYPE;
    v_amb_json   JSONB;
    v_stores     JSONB := '[]'::JSONB;
    v_payments   JSONB := '[]'::JSONB;
    v_payouts    JSONB := '[]'::JSONB;
    v_generated  NUMERIC := 0;
    v_paid       NUMERIC := 0;
    v_warnings   JSONB := '[]'::JSONB;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Sessão não autenticada.';
    END IF;

    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

    IF v_role = 'SUPERADMIN' AND p_ambassador_id IS NOT NULL THEN
        SELECT * INTO v_amb FROM public.ambassadors WHERE id = p_ambassador_id;
    ELSE
        -- Qualquer outro utilizador só pode ver o registo ligado ao seu próprio login.
        SELECT * INTO v_amb FROM public.ambassadors WHERE user_id = v_uid ORDER BY created_at LIMIT 1;
    END IF;

    IF v_amb.id IS NULL THEN
        RETURN JSONB_BUILD_OBJECT(
            'ok', FALSE,
            'code', 'AMBASSADOR_NOT_LINKED',
            'message', 'Não existe um cadastro de embaixador ligado a este login.'
        );
    END IF;

    v_amb_json := JSONB_BUILD_OBJECT(
        'id', v_amb.id,
        'user_id', v_amb.user_id,
        'name', v_amb.name,
        'phone', v_amb.phone,
        'pix_mpesa', v_amb.pix_mpesa,
        'referral_code', v_amb.referral_code,
        'commission_rate', COALESCE(v_amb.commission_rate, 0),
        'status', COALESCE(TO_JSONB(v_amb)->>'status',
                           CASE WHEN v_amb.active = FALSE THEN 'DESATIVADO' ELSE 'ATIVO' END),
        'pending_commissions', COALESCE(v_amb.pending_commissions, 0),
        'total_earned', COALESCE(v_amb.total_earned, 0),
        'created_at', v_amb.created_at
    );

    -- ---------------- LOJAS VINCULADAS (subscrição + comissão por loja) ----------------
    BEGIN
        SELECT COALESCE(JSONB_AGG(t.x ORDER BY t.created DESC NULLS LAST), '[]'::JSONB)
          INTO v_stores
          FROM (
            SELECT r.created_at AS created,
                   JSONB_BUILD_OBJECT(
                       'id', r.id,
                       'name', r.name,
                       'owner_name', r.owner_name,
                       'phone', r.phone,
                       'city', r.city,
                       'address', s.address,
                       'province', s.province,
                       'admin_email', (SELECT pf.email FROM public.profiles pf
                                        WHERE pf.store_id = s.id AND pf.role = 'ADMIN'
                                        ORDER BY pf.created_at, pf.email LIMIT 1),
                       'admin_name', (SELECT pf.full_name FROM public.profiles pf
                                        WHERE pf.store_id = s.id AND pf.role = 'ADMIN'
                                        ORDER BY pf.created_at, pf.email LIMIT 1),
                       'created_at', r.created_at,
                       'monthly_fee', COALESCE(s.valor_mensalidade, r.monthly_fee, 0),
                       'commission_rate', COALESCE(r.commission_rate, v_amb.commission_rate, 0),
                       'contract_duration_months', COALESCE(r.contract_duration_months, 12),
                       'months_active', COALESCE(r.months_active, 0),
                       'has_store', (s.id IS NOT NULL),
                       'subscription_status', CASE
                            WHEN s.id IS NULL THEN 'SEM_LOJA'
                            WHEN s.acesso_ativo = FALSE THEN 'BLOQUEADA'
                            WHEN s.data_fim_teste < CURRENT_DATE THEN 'EXPIRADA'
                            WHEN r.last_payment_date IS NULL THEN 'EM_TESTE'
                            ELSE 'ATIVA' END,
                       'subscription_end', s.data_fim_teste,
                       'days_remaining', CASE WHEN s.id IS NULL THEN NULL
                                              ELSE (s.data_fim_teste - CURRENT_DATE) END,
                       'last_payment_date', r.last_payment_date,
                       'payments_count', (SELECT COUNT(*) FROM public.ambassador_commission_payments p
                                           WHERE p.referred_store_id = r.id),
                       'total_paid_by_store', (SELECT COALESCE(SUM(p.payment_amount), 0)
                                                 FROM public.ambassador_commission_payments p
                                                WHERE p.referred_store_id = r.id),
                       'total_commission', (SELECT COALESCE(SUM(p.commission_amount), 0)
                                              FROM public.ambassador_commission_payments p
                                             WHERE p.referred_store_id = r.id)
                   ) AS x
              FROM public.ambassador_referred_stores r
              LEFT JOIN LATERAL (
                    SELECT q.* FROM (
                        SELECT s1.*, 1 AS prio
                          FROM public.stores s1
                         WHERE s1.id = COALESCE(r.store_id, r.id)
                        UNION ALL
                        SELECT s2.*, 2 AS prio
                          FROM public.stores s2
                         WHERE r.store_id IS NULL
                           AND NOT EXISTS (SELECT 1 FROM public.stores x1 WHERE x1.id = r.id)
                           AND REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g') <> ''
                           AND LOWER(TRIM(s2.name)) = LOWER(TRIM(r.name))
                           AND REGEXP_REPLACE(COALESCE(s2.phone, ''), '\D', '', 'g')
                             = REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g')
                           AND NOT EXISTS (SELECT 1 FROM public.ambassador_referred_stores z
                                            WHERE z.store_id = s2.id)
                           AND (SELECT COUNT(*) FROM public.stores y
                                 WHERE LOWER(TRIM(y.name)) = LOWER(TRIM(r.name))
                                   AND REGEXP_REPLACE(COALESCE(y.phone, ''), '\D', '', 'g')
                                     = REGEXP_REPLACE(COALESCE(r.phone, ''), '\D', '', 'g')) = 1
                    ) q
                    ORDER BY q.prio
                    LIMIT 1
              ) s ON TRUE
             WHERE r.ambassador_id = v_amb.id
          ) t;
    EXCEPTION WHEN OTHERS THEN
        v_warnings := v_warnings || TO_JSONB('lojas: ' || SQLERRM);
    END;

    -- ---------------- COMISSÃO GERADA EM CADA PAGAMENTO ----------------
    BEGIN
        SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
                   'id', p.id,
                   'referred_store_id', p.referred_store_id,
                   'store_name', p.store_name,
                   'paid_at', p.paid_at,
                   'payment_amount', p.payment_amount,
                   'commission_rate', p.commission_rate,
                   'commission_amount', p.commission_amount,
                   'days_added', p.days_added
               ) ORDER BY p.paid_at DESC), '[]'::JSONB),
               COALESCE(SUM(p.commission_amount), 0)
          INTO v_payments, v_generated
          FROM public.ambassador_commission_payments p
         WHERE p.ambassador_id = v_amb.id;
    EXCEPTION WHEN OTHERS THEN
        v_warnings := v_warnings || TO_JSONB('pagamentos: ' || SQLERRM);
    END;

    -- ---------------- HISTÓRICO DE LIQUIDAÇÕES (comissão recebida) ----------------
    BEGIN
        SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
                   'id', po.id,
                   'amount', po.amount,
                   'method', po.method,
                   'receipt', po.receipt,
                   'status', po.status,
                   'created_at', po.created_at
               ) ORDER BY po.created_at DESC), '[]'::JSONB),
               COALESCE(SUM(po.amount), 0)
          INTO v_payouts, v_paid
          FROM public.ambassador_payouts po
         WHERE po.ambassador_id = v_amb.id;
    EXCEPTION WHEN OTHERS THEN
        v_warnings := v_warnings || TO_JSONB('liquidacoes: ' || SQLERRM);
    END;

    RETURN JSONB_BUILD_OBJECT(
        'ok', TRUE,
        'generated_at', NOW(),
        'ambassador', v_amb_json,
        'stores', v_stores,
        'payments', v_payments,
        'payouts', v_payouts,
        'total_commission_generated', v_generated,
        'available_commission', COALESCE(v_amb.pending_commissions, 0),
        'paid_commission', v_paid,
        'warnings', v_warnings
    );
END;
$$;
REVOKE ALL ON FUNCTION public.fn_ambassador_portal(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_ambassador_portal(TEXT) TO authenticated;

-- ------------------------------------------------------------------------------
-- 4. LEITURA DO EMBAIXADOR SOBRE OS PRÓPRIOS DADOS (ele nunca ganha escrita)
--    Mantém o Realtime a entregar eventos só das linhas do próprio embaixador.
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS "ambassadors_self_read" ON public.ambassadors;
CREATE POLICY "ambassadors_self_read" ON public.ambassadors FOR SELECT TO authenticated
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "ambassador_referred_stores_owner_select" ON public.ambassador_referred_stores;
CREATE POLICY "ambassador_referred_stores_owner_select" ON public.ambassador_referred_stores FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.ambassadors a
                WHERE a.id = ambassador_referred_stores.ambassador_id
                  AND a.user_id = auth.uid()));

DROP POLICY IF EXISTS "ambassador_payouts_owner_select" ON public.ambassador_payouts;
CREATE POLICY "ambassador_payouts_owner_select" ON public.ambassador_payouts FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.ambassadors a
                WHERE a.id = ambassador_payouts.ambassador_id
                  AND a.user_id = auth.uid()));

DROP POLICY IF EXISTS "amb_comm_payments_select" ON public.ambassador_commission_payments;
CREATE POLICY "amb_comm_payments_select" ON public.ambassador_commission_payments FOR SELECT TO authenticated
USING (
    public.get_auth_user_role() = 'SUPERADMIN'
    OR EXISTS (SELECT 1 FROM public.ambassadors a
                WHERE a.id = ambassador_commission_payments.ambassador_id
                  AND a.user_id = auth.uid())
);

-- ------------------------------------------------------------------------------
-- 5. REALTIME (o painel actualiza sozinho após cada pagamento/liquidação)
-- ------------------------------------------------------------------------------
DO $rt$
DECLARE
    t TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH t IN ARRAY ARRAY[
            'ambassadors',
            'ambassador_referred_stores',
            'ambassador_commission_payments',
            'ambassador_payouts'
        ] LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
            ) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
            END IF;
        END LOOP;
    END IF;
END
$rt$;

-- Faz o PostgREST (API do Supabase) reconhecer a nova função de imediato.
NOTIFY pgrst, 'reload schema';

-- ==============================================================================
-- DIAGNÓSTICO (opcional; só leitura). Execute à parte, DEPOIS da migração.
-- Uma linha por embaixador: mostra exactamente porque um painel estaria vazio.
-- ==============================================================================
-- SELECT a.id, a.name, a.referral_code,
--        (a.user_id IS NOT NULL)                              AS login_ligado,
--        pf.role                                              AS funcao_do_login,
--        pf.active                                            AS login_activo,
--        (SELECT COUNT(*) FROM public.ambassador_referred_stores r WHERE r.ambassador_id = a.id) AS lojas_vinculadas,
--        (SELECT COUNT(*) FROM public.ambassador_referred_stores r
--          WHERE r.ambassador_id = a.id AND r.store_id IS NULL
--            AND NOT EXISTS (SELECT 1 FROM public.stores s WHERE s.id = r.id))                    AS lojas_sem_loja_real,
--        (SELECT COUNT(*) FROM public.ambassador_commission_payments p WHERE p.ambassador_id = a.id) AS pagamentos_com_comissao,
--        a.pending_commissions                                AS comissao_disponivel
--   FROM public.ambassadors a
--   LEFT JOIN public.profiles pf ON pf.id = a.user_id
--  ORDER BY a.created_at;
--
-- Leitura: login_ligado = false  -> o embaixador nunca verá nada (ligue o login);
--          funcao_do_login <> 'EMBAIXADOR' ou login_activo = false -> o login não abre o painel;
--          lojas_sem_loja_real > 0 -> lojas registadas só como "indicação", sem loja real.
--
-- Ligar um login existente a um embaixador (substitua os dois valores):
--   UPDATE public.ambassadors SET user_id = '<id do perfil>' WHERE id = '<id do embaixador>';
