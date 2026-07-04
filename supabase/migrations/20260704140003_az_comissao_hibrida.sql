-- ============================================================
-- Amazon: comissão híbrida (estimada + real via Finances API)
-- Estimada = ReferralFee (12%, getMyFeesEstimate), disponível na hora.
-- Real = Commission + AmazonForAllFee (Finances API, ~48h delay).
-- O RPC usa a real onde existe, a estimada onde não.
-- ============================================================

-- 1. Tabela de comissão por pedido
CREATE TABLE public.az_comissao (
  amazon_order_id TEXT PRIMARY KEY REFERENCES az_pedidos(amazon_order_id),
  comissao_estimada NUMERIC(12,2) NOT NULL,
  comissao_real NUMERIC(12,2),
  confirmado BOOLEAN NOT NULL DEFAULT false,
  fonte TEXT NOT NULL DEFAULT 'estimate',
  atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.az_comissao ENABLE ROW LEVEL SECURITY;

-- 2. RPC: comissão do mês (usa real onde existe, estimada onde não)
CREATE OR REPLACE FUNCTION public.az_comissao(p_month text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'comissao_total', COALESCE(SUM(COALESCE(c.comissao_real, c.comissao_estimada)), 0),
    'pedidos_confirmados', COUNT(*) FILTER (WHERE c.confirmado),
    'pedidos_total', COUNT(*)
  )
  FROM public.az_comissao c
  JOIN public.az_pedidos p ON p.amazon_order_id = c.amazon_order_id
  WHERE to_char(p.purchase_date, 'YYYY-MM') = p_month
    AND p.status NOT IN ('Canceled', 'Pending', 'Unfulfillable');
$$;

-- 3. Upsert em lote (para cron)
CREATE OR REPLACE FUNCTION public.az_upsert_comissao(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_count integer := 0;
BEGIN
  INSERT INTO public.az_comissao (amazon_order_id, comissao_estimada, comissao_real, confirmado, fonte, atualizado_em)
  SELECT
    r->>'amazon_order_id',
    (r->>'comissao_estimada')::numeric,
    CASE WHEN r->>'comissao_real' IS NOT NULL THEN (r->>'comissao_real')::numeric END,
    COALESCE((r->>'confirmado')::boolean, false),
    COALESCE(r->>'fonte', 'estimate'),
    now()
  FROM jsonb_array_elements(p_rows) AS r
  ON CONFLICT (amazon_order_id) DO UPDATE SET
    comissao_estimada = EXCLUDED.comissao_estimada,
    comissao_real     = COALESCE(EXCLUDED.comissao_real, az_comissao.comissao_real),
    confirmado        = COALESCE(EXCLUDED.confirmado, az_comissao.confirmado),
    fonte             = CASE WHEN EXCLUDED.comissao_real IS NOT NULL THEN EXCLUDED.fonte ELSE az_comissao.fonte END,
    atualizado_em     = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
