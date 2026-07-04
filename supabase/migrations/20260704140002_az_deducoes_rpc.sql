-- ============================================================
-- Amazon: deduções do Settlement (comissão, Easy Ship, refund)
-- Competência por purchase_date (igual a bruta).
-- ============================================================

CREATE OR REPLACE FUNCTION public.az_deducoes(p_month text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'comissao', COALESCE(SUM(CASE
      WHEN amount_description IN ('Commission', 'Flexible Customer Financing fee')
      THEN ABS(amount) END), 0),
    'easy_ship', COALESCE(SUM(CASE
      WHEN amount_description = 'Amazon Easy Ship Charges'
      THEN ABS(amount) END), 0),
    'refund', COALESCE(SUM(CASE
      WHEN transaction_type IN ('Refund', 'refund') AND amount_description = 'Principal'
      THEN ABS(amount) END), 0),
    'pedidos_com_comissao', (
      SELECT COUNT(DISTINCT order_id)
      FROM public.az_settlement
      WHERE to_char(purchase_date, 'YYYY-MM') = p_month
        AND amount_description = 'Commission'
    ),
    'pedidos_total', (
      SELECT COUNT(*)
      FROM public.az_pedidos
      WHERE to_char(purchase_date, 'YYYY-MM') = p_month
        AND status NOT IN ('Canceled', 'Pending', 'Unfulfillable')
    )
  )
  FROM public.az_settlement
  WHERE to_char(purchase_date, 'YYYY-MM') = p_month;
$$;
