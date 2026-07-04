-- Amazon: itens por pedido (seller-sku + qty) + CMV via ml_custo_produto

CREATE TABLE public.az_itens (
  amazon_order_id TEXT NOT NULL REFERENCES az_pedidos(amazon_order_id),
  seller_sku TEXT NOT NULL,
  asin TEXT,
  quantidade INTEGER NOT NULL DEFAULT 1,
  preco_unitario NUMERIC(12,2),
  atualizado_em TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (amazon_order_id, seller_sku)
);
ALTER TABLE public.az_itens ENABLE ROW LEVEL SECURITY;

-- Upsert itens
CREATE OR REPLACE FUNCTION public.az_upsert_itens(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_count integer := 0;
BEGIN
  INSERT INTO public.az_itens (amazon_order_id, seller_sku, asin, quantidade, preco_unitario, atualizado_em)
  SELECT
    r->>'amazon_order_id',
    r->>'seller_sku',
    r->>'asin',
    COALESCE((r->>'quantidade')::int, 1),
    CASE WHEN r->>'preco_unitario' IS NOT NULL THEN (r->>'preco_unitario')::numeric END,
    now()
  FROM jsonb_array_elements(p_rows) AS r
  ON CONFLICT (amazon_order_id, seller_sku) DO UPDATE SET
    asin           = COALESCE(EXCLUDED.asin, az_itens.asin),
    quantidade     = EXCLUDED.quantidade,
    preco_unitario = COALESCE(EXCLUDED.preco_unitario, az_itens.preco_unitario),
    atualizado_em  = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- CMV mensal: custo × quantidade, régua paid+partial (exclui Canceled/Pending/Unfulfillable)
CREATE OR REPLACE FUNCTION public.az_cmv(p_month text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'cmv_total', COALESCE(SUM(c.custo * i.quantidade), 0),
    'itens_com_custo', COUNT(*) FILTER (WHERE c.custo IS NOT NULL),
    'itens_total', COUNT(*)
  )
  FROM public.az_itens i
  JOIN public.az_pedidos p ON p.amazon_order_id = i.amazon_order_id
  LEFT JOIN public.ml_custo_produto c ON c.sku = i.seller_sku
  WHERE to_char(p.purchase_date, 'YYYY-MM') = p_month
    AND p.status NOT IN ('Canceled', 'Pending', 'Unfulfillable');
$$;
