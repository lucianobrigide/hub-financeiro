-- Amazon: frete híbrido (estimado R$27,95 flat + real via Finances API MFNPostageFee)

CREATE TABLE public.az_frete (
  amazon_order_id TEXT PRIMARY KEY REFERENCES az_pedidos(amazon_order_id),
  frete_estimado NUMERIC(12,2) NOT NULL,
  frete_real NUMERIC(12,2),
  confirmado BOOLEAN NOT NULL DEFAULT false,
  fonte TEXT NOT NULL DEFAULT 'estimate',
  atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.az_frete ENABLE ROW LEVEL SECURITY;

-- Upsert (OR preserva confirmado, COALESCE preserva real)
CREATE OR REPLACE FUNCTION public.az_upsert_frete(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_count integer := 0;
BEGIN
  INSERT INTO public.az_frete (amazon_order_id, frete_estimado, frete_real, confirmado, fonte, atualizado_em)
  SELECT
    r->>'amazon_order_id',
    (r->>'frete_estimado')::numeric,
    CASE WHEN r->>'frete_real' IS NOT NULL THEN (r->>'frete_real')::numeric END,
    COALESCE((r->>'confirmado')::boolean, false),
    COALESCE(r->>'fonte', 'estimate'),
    now()
  FROM jsonb_array_elements(p_rows) AS r
  ON CONFLICT (amazon_order_id) DO UPDATE SET
    frete_estimado = EXCLUDED.frete_estimado,
    frete_real     = COALESCE(EXCLUDED.frete_real, az_frete.frete_real),
    confirmado     = az_frete.confirmado OR EXCLUDED.confirmado,
    fonte          = CASE WHEN EXCLUDED.frete_real IS NOT NULL THEN EXCLUDED.fonte ELSE az_frete.fonte END,
    atualizado_em  = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Pendentes (frete não confirmado)
CREATE OR REPLACE FUNCTION public.az_pendentes_frete()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'amazon_order_id', f.amazon_order_id,
    'frete_estimado', f.frete_estimado
  )), '[]'::jsonb)
  FROM public.az_frete f
  WHERE NOT f.confirmado;
$$;

-- Resumo mensal (híbrido: real onde confirmado, estimado onde não)
CREATE OR REPLACE FUNCTION public.az_frete_mes(p_month text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'frete_total', COALESCE(SUM(COALESCE(f.frete_real, f.frete_estimado)), 0),
    'pedidos_confirmados', COUNT(*) FILTER (WHERE f.confirmado),
    'pedidos_total', COUNT(*)
  )
  FROM public.az_frete f
  JOIN public.az_pedidos p ON p.amazon_order_id = f.amazon_order_id
  WHERE to_char(p.purchase_date, 'YYYY-MM') = p_month
    AND p.status NOT IN ('Canceled', 'Pending', 'Unfulfillable');
$$;
