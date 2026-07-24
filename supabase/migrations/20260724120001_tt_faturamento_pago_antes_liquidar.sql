-- TikTok: alinhar à regra do ML/Shopee — contar o pedido PAGO assim que a venda acontece,
-- sem esperar a liquidação do TikTok. Antes, tt_faturamento e tt_cmv exigiam fin_filled, então
-- pedidos pagos-mas-não-liquidados (AWAITING_SHIPMENT, IN_TRANSIT, DELIVERED sem statement)
-- não contavam — o faturamento do mês corrente ficava quase zerado. (Luciano, 24/07/2026.)
--
-- Regra alinhada:
--   * Receita/CMV contam todo pedido pago (exclui UNPAID e CANCELLED). Receita = fin_revenue
--     quando liquidado, senão payment_total (estimativa; refina na liquidação). CMV = custo do
--     produto (ml_custo_produto), conhecido na hora.
--   * Deduções (comissão/frete/taxas/ads/afiliados) continuam vindo da liquidação — a nota
--     "X de Y liquidados" (tt_deducoes.pedidos de tt_faturamento.total_pedidos) mostra a cobertura.
--   * Revisão de cancelados: tt_cron_diario re-sincroniza order_status numa janela de 7 dias e
--     tt_cron_semanal (domingo) em 30 dias — pedido que cancela depois é corrigido no Hub.

CREATE OR REPLACE FUNCTION public.tt_faturamento(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  with b as (
    select
      sum(case when fin_filled then coalesce(fin_revenue,0) else coalesce(payment_total,0) end) as revenue,
      sum( coalesce((fin_rev_breakdown->>'refund_subtotal_before_discount_amount')::numeric,0)
         + coalesce((fin_rev_breakdown->>'seller_discount_refund_amount')::numeric,0)
         ) filter (where fin_filled) as refund_net,
      count(*) as pedidos,
      count(*) filter (where fin_filled) as pedidos_liq,
      sum(fin_settlement) filter (where fin_filled) as settlement
    from public.tt_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status not in ('CANCELLED','UNPAID')
  )
  select jsonb_build_object(
    'faturamento_bruto',   coalesce(revenue - refund_net, 0),
    'devolucoes',          coalesce(-refund_net, 0),
    'faturamento_liquido', coalesce(revenue, 0),
    'total_pedidos',       coalesce(pedidos, 0),
    'pedidos_liquidados',  coalesce(pedidos_liq, 0),
    'settlement',          coalesce(settlement, 0)
  ) from b;
$function$;

CREATE OR REPLACE FUNCTION public.tt_cmv(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  select jsonb_build_object(
    'cmv_total',       coalesce(sum(c.custo*i.quantity),0),
    'itens_com_custo', count(c.custo),
    'itens_total',     count(*)
  )
  from public.tt_itens i
  join public.tt_pedidos p on p.order_id=i.order_id
  left join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.seller_sku,''),''))
  where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
    and i.line_status<>'CANCELLED' and p.order_status not in ('CANCELLED','UNPAID');
$function$;
