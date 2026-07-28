-- ============================================================
-- TikTok: remove o DRIFT VIVO do tt_deducoes + expõe cobertura p/ o piso de exibição.
--
-- O tt_deducoes vivo ESTIMAVA as deduções dos não-liquidados (6,0%/2,1%/8,2% do
-- payment_total, frete de fora) via uma CTE `est` — código não versionado, aplicado
-- direto no banco, sem SHA. Teste ao vivo (28/07/2026) no order detail
-- GET /order/202309/orders provou que o pedido NÃO traz fee_breakdown antes de liquidar
-- (só payment/preço/desconto), e o /finance devolve zeros até liquidar → o dado de
-- dedução NÃO EXISTE antes do settlement. REGRA DURA (Luciano, 28/07/2026): nada é
-- estimado/arbitrado/preenchido por percentual — tudo vem da API; sem dado, mostra-se
-- cobertura, não aproximação.
--
-- Portanto: tt_deducoes VOLTA ao settled-only (corpo versionado de 20260710210001).
-- tt_faturamento e tt_cmv ganham os agregados do SUBCONJUNTO LIQUIDADO (liquido_liquidado,
-- cmv_liquidado) e a cobertura ponderada por receita (pago_total/pago_liquidado), para o
-- provider (a) exibir "em consolidação" abaixo do piso e (b) calcular a M.C. acima do piso
-- sobre o subconjunto liquidado dos DOIS lados (receita e deduções do mesmo conjunto).
--
-- Junho não se move: 100% liquidado → a CTE `est` removida já contribuía 0, e os novos
-- agregados *_liquidado coincidem com os totais. Campos de saída antigos ficam idênticos.
-- ============================================================

-- 1. tt_deducoes → SETTLED-ONLY (sem estimativa)
CREATE OR REPLACE FUNCTION public.tt_deducoes(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  WITH b AS (
    SELECT
      -sum(fin_commission) AS comissao,
      -sum(coalesce((fin_breakdown->>'affiliate_commission_amount')::numeric,0)) AS afiliados,
      -sum(
         coalesce((fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
       + coalesce((fin_breakdown->>'gmv_max_ad_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'smart_promotion_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'tap_shop_ads_commission')::numeric,0)
       + coalesce((fin_breakdown->>'cps_shop_ads_commission_tax_amount')::numeric,0)
       + coalesce((fin_breakdown->>'brand_amplification_program_commission')::numeric,0)
       + coalesce((fin_breakdown->>'brand_campaign_fee')::numeric,0)
       + coalesce((fin_breakdown->>'category_led_campaign_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'campaign_period_fee_cfp_amount')::numeric,0)
       + coalesce((fin_breakdown->>'campaign_period_fee_sp_amount')::numeric,0)
       + coalesce((fin_breakdown->>'live_specials_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'flash_sales_service_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'cofunded_creator_bonus_amount')::numeric,0)
       + coalesce((fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0)
      ) AS ads,
      -sum(fin_frete)   AS frete,
      -sum(fin_fee_tax) AS fee_tax_total,
      count(*)          AS pedidos
    FROM public.tt_pedidos
    WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo','YYYY-MM')=p_month
      AND order_status<>'CANCELLED' AND fin_filled
  )
  SELECT jsonb_build_object(
    'comissao',  coalesce(comissao,0),
    'afiliados', coalesce(afiliados,0),
    'ads',       coalesce(ads,0),
    'frete',     coalesce(frete,0),
    'taxas',     coalesce(fee_tax_total - comissao - afiliados - ads,0),  -- residual (PLUG: campo novo no fin_fee_tax cai aqui; ver LICOES.md)
    'pedidos',   coalesce(pedidos,0)
  ) FROM b;
$function$;

-- 2. tt_faturamento → +liquido_liquidado (receita do subconjunto liquidado) e cobertura por receita
CREATE OR REPLACE FUNCTION public.tt_faturamento(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  WITH b AS (
    SELECT
      sum(case when fin_filled then coalesce(fin_revenue,0) else coalesce(payment_total,0) end) AS revenue,
      sum(fin_revenue) filter (where fin_filled) AS revenue_liq,
      sum( coalesce((fin_rev_breakdown->>'refund_subtotal_before_discount_amount')::numeric,0)
         + coalesce((fin_rev_breakdown->>'seller_discount_refund_amount')::numeric,0)
         ) filter (where fin_filled) AS refund_net,
      count(*) AS pedidos,
      count(*) filter (where fin_filled) AS pedidos_liq,
      sum(payment_total) AS pago_total,
      sum(payment_total) filter (where fin_filled) AS pago_liq,
      sum(fin_settlement) filter (where fin_filled) AS settlement
    FROM public.tt_pedidos
    WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo','YYYY-MM')=p_month
      AND order_status not in ('CANCELLED','UNPAID')
  )
  SELECT jsonb_build_object(
    'faturamento_bruto',   coalesce(revenue - refund_net, 0),
    'devolucoes',          coalesce(-refund_net, 0),
    'faturamento_liquido', coalesce(revenue, 0),
    'liquido_liquidado',   coalesce(revenue_liq, 0),          -- receita SÓ do liquidado (base da M.C. acima do piso)
    'total_pedidos',       coalesce(pedidos, 0),
    'pedidos_liquidados',  coalesce(pedidos_liq, 0),
    'pago_total',          coalesce(pago_total, 0),            -- cobertura ponderada por receita:
    'pago_liquidado',      coalesce(pago_liq, 0),              --   pago_liquidado / pago_total
    'settlement',          coalesce(settlement, 0)
  ) FROM b;
$function$;

-- 3. tt_cmv → +cmv_liquidado (CMV do subconjunto liquidado, p/ a M.C. fechar dos dois lados)
CREATE OR REPLACE FUNCTION public.tt_cmv(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  SELECT jsonb_build_object(
    'cmv_total',        coalesce(sum(c.custo*i.quantity),0),
    'cmv_liquidado',    coalesce(sum(c.custo*i.quantity) filter (where p.fin_filled),0),
    'itens_com_custo',  count(c.custo),
    'itens_total',      count(*),
    'itens_liquidados', count(*) filter (where p.fin_filled)
  )
  FROM public.tt_itens i
  JOIN public.tt_pedidos p ON p.order_id=i.order_id
  LEFT JOIN public.ml_custo_produto c ON c.sku = unaccent(coalesce(nullif(i.seller_sku,''),''))
  WHERE to_char(p.create_time AT TIME ZONE 'America/Sao_Paulo','YYYY-MM')=p_month
    AND i.line_status<>'CANCELLED' AND p.order_status not in ('CANCELLED','UNPAID');
$function$;

REVOKE ALL ON FUNCTION public.tt_deducoes(text)    FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_faturamento(text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_cmv(text)         FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tt_deducoes(text)    TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_faturamento(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_cmv(text)         TO service_role;
