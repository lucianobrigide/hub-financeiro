-- Bloco TikTok do DRE diário passa a usar provisão para pedidos não liquidados
-- (comissão/sfp/fee_item/outras via take-rate; afiliado real via aff_commission
-- quando houver; ads: tt_ads_diario real por dia > settlement+provisão).
-- PERF: os CTEs tt_rates/tt_q PRECISAM de "as materialized" — referenciados uma
-- vez, o Postgres os inlina e reavalia tt_take_rates() POR LINHA (0,3s -> 9s).
-- Demais canais inalterados.
CREATE OR REPLACE FUNCTION public.dre_diario_canais(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with
  sp_ped as (
    select (create_time at time zone 'America/Sao_Paulo')::date d,
           sum(selling_price) fat, sum(escrow_amount) repasse
    from public.shopee_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and selling_price is not null
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  sp_cmv as (
    select (p.create_time at time zone 'America/Sao_Paulo')::date d, sum(c.custo*i.quantity) cmv
    from public.shopee_itens i
    join public.shopee_pedidos p on p.order_sn=i.order_sn
    join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.model_sku,''), i.item_sku))
      and (p.create_time at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
      and (c.vigencia_fim is null or (p.create_time at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
    where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and p.selling_price is not null
    group by 1),
  sp_ads as (
    select data d, sum(expense) ads from public.shopee_ads_diario
    where to_char(data,'YYYY-MM')=p_month and data < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  sp as (
    select 'sp'::text canal, sp_ped.d, sp_ped.fat,
      coalesce(sp_cmv.cmv,0) cmv,
      (sp_ped.fat - sp_ped.repasse) comissao,
      0::numeric frete,
      coalesce(sp_ads.ads,0) ads
    from sp_ped left join sp_cmv on sp_cmv.d=sp_ped.d left join sp_ads on sp_ads.d=sp_ped.d),
  tt_rates as materialized (select public.tt_take_rates(60) r),
  tt_q as materialized (select order_id, sum(quantity) q from public.tt_itens where line_status<>'CANCELLED' group by 1),
  tt_ord as (
    select (p.create_time at time zone 'America/Sao_Paulo')::date d,
      case when p.fin_filled then coalesce(p.fin_revenue,0) else coalesce(p.payment_total,0) end fat,
      case when p.fin_filled then
        -coalesce(p.fin_fee_tax,0)
        + ( coalesce((p.fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'gmv_max_ad_fee_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'smart_promotion_fee_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'tap_shop_ads_commission')::numeric,0)
          + coalesce((p.fin_breakdown->>'cps_shop_ads_commission_tax_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'brand_amplification_program_commission')::numeric,0)
          + coalesce((p.fin_breakdown->>'brand_campaign_fee')::numeric,0)
          + coalesce((p.fin_breakdown->>'category_led_campaign_fee_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'campaign_period_fee_cfp_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'campaign_period_fee_sp_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'live_specials_fee_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'flash_sales_service_fee_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'cofunded_creator_bonus_amount')::numeric,0)
          + coalesce((p.fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0) )
      else
        ( (r.r->>'comissao_pct')::numeric + (r.r->>'sfp_pct')::numeric + (r.r->>'outras_pct')::numeric ) * coalesce(p.payment_total,0)
        + (r.r->>'fee_item')::numeric * coalesce(tt_q.q,1)
        + case when p.aff_filled then coalesce(p.aff_commission,0)
               else (r.r->>'afiliado_pct')::numeric * coalesce(p.payment_total,0) end
      end taxas,
      case when p.fin_filled then -coalesce(p.fin_frete,0)
           else (r.r->>'frete_pct')::numeric * coalesce(p.payment_total,0) end frete,
      case when p.fin_filled then
        -( coalesce((p.fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'gmv_max_ad_fee_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'smart_promotion_fee_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'tap_shop_ads_commission')::numeric,0)
         + coalesce((p.fin_breakdown->>'cps_shop_ads_commission_tax_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'brand_amplification_program_commission')::numeric,0)
         + coalesce((p.fin_breakdown->>'brand_campaign_fee')::numeric,0)
         + coalesce((p.fin_breakdown->>'category_led_campaign_fee_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'campaign_period_fee_cfp_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'campaign_period_fee_sp_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'live_specials_fee_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'flash_sales_service_fee_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'cofunded_creator_bonus_amount')::numeric,0)
         + coalesce((p.fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0) )
      else (r.r->>'ads_pct')::numeric * coalesce(p.payment_total,0) end ads_settle
    from public.tt_pedidos p
    left join tt_q on tt_q.order_id = p.order_id
    cross join tt_rates r
    where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in ('CANCELLED','UNPAID')
      and (p.create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
  ),
  tt_ads as (
    select data d, sum(cost) ads from public.tt_ads_diario
    where to_char(data,'YYYY-MM')=p_month and data < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  tt_ped as (
    select o.d, sum(o.fat) fat, sum(o.taxas) taxas, sum(o.frete) frete, sum(o.ads_settle) ads_settle
    from tt_ord o group by 1),
  tt_cmv as (
    select (p.create_time at time zone 'America/Sao_Paulo')::date d, sum(c.custo*i.quantity) cmv
    from public.tt_itens i join public.tt_pedidos p on p.order_id=i.order_id
    join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.seller_sku,''),''))
      and (p.create_time at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
      and (c.vigencia_fim is null or (p.create_time at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
    where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and i.line_status<>'CANCELLED' and p.order_status not in ('CANCELLED','UNPAID')
    group by 1),
  tt as (
    select 'tt'::text canal, tt_ped.d, tt_ped.fat,
      coalesce(tt_cmv.cmv,0) cmv, tt_ped.taxas comissao, tt_ped.frete frete,
      coalesce(tt_ads.ads, tt_ped.ads_settle, 0) ads
    from tt_ped
    left join tt_cmv on tt_cmv.d=tt_ped.d
    left join tt_ads on tt_ads.d=tt_ped.d),
  az_ped as (
    select purchase_date::date d, sum(total) fat from public.az_pedidos
    where to_char(purchase_date,'YYYY-MM')=p_month and status not in ('Canceled','Pending','Unfulfillable')
      and purchase_date::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  az_com as (
    select p.purchase_date::date d, sum(coalesce(c.comissao_real,c.comissao_estimada)) com
    from public.az_comissao c join public.az_pedidos p on p.amazon_order_id=c.amazon_order_id
    where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')
    group by 1),
  az_fr as (
    select p.purchase_date::date d, sum(coalesce(f.frete_real,f.frete_estimado)) fr
    from public.az_frete f join public.az_pedidos p on p.amazon_order_id=f.amazon_order_id
    where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')
    group by 1),
  az_cmv as (
    select p.purchase_date::date d, sum(c.custo*i.quantidade) cmv
    from public.az_itens i join public.az_pedidos p on p.amazon_order_id=i.amazon_order_id
    join public.ml_custo_produto c on c.sku=i.seller_sku
      and p.purchase_date >= c.vigencia_inicio
      and (c.vigencia_fim is null or p.purchase_date < c.vigencia_fim)
    where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')
    group by 1),
  az_ads as (
    select data d, sum(cost) ads from public.azads_gastos
    where to_char(data,'YYYY-MM')=p_month and data < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  az as (
    select 'az'::text canal, coalesce(az_ped.d, az_ads.d) d, coalesce(az_ped.fat,0) fat,
      coalesce(az_cmv.cmv,0) cmv, coalesce(az_com.com,0) comissao, coalesce(az_fr.fr,0) frete,
      coalesce(az_ads.ads,0) ads
    from az_ped
    full join az_ads on az_ads.d=az_ped.d
    left join az_com on az_com.d=coalesce(az_ped.d, az_ads.d)
    left join az_fr on az_fr.d=coalesce(az_ped.d, az_ads.d)
    left join az_cmv on az_cmv.d=coalesce(az_ped.d, az_ads.d)),
  b2b_ped as (
    select n.data_emissao::date d, sum(n.valor_total) fat from public.b2b_notas n
    where to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
      and n.data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  b2b_cmv as (
    select n.data_emissao::date d, sum(i.quantidade*c.custo) cmv
    from public.b2b_itens i join public.b2b_notas n on n.id=i.nota_id
    join public.ml_custo_produto c on c.sku=i.sku
      and n.data_emissao >= c.vigencia_inicio
      and (c.vigencia_fim is null or n.data_emissao < c.vigencia_fim)
    where to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
    group by 1),
  b2b as (
    select 'b2b'::text canal, b2b_ped.d, b2b_ped.fat,
      coalesce(b2b_cmv.cmv,0) cmv, 0::numeric comissao, 0::numeric frete, 0::numeric ads
    from b2b_ped left join b2b_cmv on b2b_cmv.d=b2b_ped.d),
  sh_ped as (
    select (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date d,
           sum(coalesce(i.preco_com_desconto,0)) fat,
           sum(coalesce(i.comissao,0)+coalesce(i.taxa_servico,0)
               - ((coalesce(i.preco,0)-coalesce(i.cupom,0)-coalesce(i.promo,0)) - coalesce(i.preco_com_desconto,0))) ded
    from public.shein_itens i
    join public.shein_pedidos p on p.order_no=i.order_no
    where to_char(coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in (6,8,9)
      and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  sh_cmv as (
    select (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date d, sum(c.custo) cmv
    from public.shein_itens i
    join public.shein_pedidos p on p.order_no=i.order_no
    join public.ml_custo_produto c on c.sku = unaccent(i.seller_sku)
      and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
      and (c.vigencia_fim is null or (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
    where to_char(coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in (6,8,9)
      and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  sh as (
    select 'sh'::text canal, sh_ped.d, sh_ped.fat,
      coalesce(sh_cmv.cmv,0) cmv,
      sh_ped.ded comissao,
      0::numeric frete, 0::numeric ads
    from sh_ped left join sh_cmv on sh_cmv.d=sh_ped.d),
  todos as (select * from sp union all select * from tt union all select * from az union all select * from b2b union all select * from sh)
  select coalesce(jsonb_agg(jsonb_build_object(
    'canal',canal,'data',to_char(d,'DD/MM'),
    'fat',round(fat,2),'cmv',round(cmv,2),'comissao',round(comissao,2),
    'frete',round(frete,2),'ads',round(ads,2)
  ) order by d, canal),'[]'::jsonb) from todos;
$function$;
