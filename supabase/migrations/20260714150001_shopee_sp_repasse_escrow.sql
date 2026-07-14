-- Shopee — M.C. ancorada no REPASSE REAL (escrow).
--
-- PROBLEMA: a M.C. era reconstruida "preco - taxas BRUTAS", metodo que ignora os creditos
-- que a Shopee devolve (subsidio de frete, reembolso de voucher). Ficava ~R$15,5k
-- pessimista: junho dava -R$18.812 quando o repasse real (o dinheiro que caiu na conta)
-- dizia -R$5.166.
--
-- FIX: sp_repasse expoe o repasse real (escrow_amount) do mes. O card monta a linha
-- "Comissao e Fretes reais cobrados" = (bruta - repasse) - afiliados: o que a Shopee
-- EFETIVAMENTE reteve, ja liquido de subsidio. A conta fecha na aritmetica visivel:
-- Liquido - comissao/frete real - ADS - Full - Afiliados - DIFAL - CMV - Devolucoes = M.C.
--
-- VALIDADO contra os relatorios oficiais (junho/2026): comissao liq + servico liq do
-- relatorio de pedidos = R$164.544,52 = o Hub AO CENTAVO; 4.571 nao-cancelados identicos.
-- Confirmado por teste na API: o escrow traz as deducoes LIQUIDAS desde a venda
-- (actual_shipping_fee ja com shopee_shipping_rebate creditado, inclusive em READY_TO_SHIP).
-- Capturado via pg_get_functiondef (repo == banco).

CREATE OR REPLACE FUNCTION public.sp_repasse(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'repasse_total',        COALESCE(SUM(escrow_amount), 0),
    'pedidos_total',        COUNT(*),
    'pedidos_com_repasse',  COUNT(*) FILTER (WHERE escrow_amount > 0),
    'pedidos_zero',         COUNT(*) FILTER (WHERE escrow_amount = 0),
    'pedidos_neg',          COUNT(*) FILTER (WHERE escrow_amount < 0)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING');
$function$;
