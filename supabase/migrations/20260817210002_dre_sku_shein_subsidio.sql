-- dre_sku: separa o SUBSÍDIO da SHEIN da linha de comissão (mesma correção que a
-- 20260817210001 fez em dre_diario_canais).
--
-- Antes, o ramo 'sh' devolvia comissao = (comissão + taxa de serviço − subsídio). Como o
-- subsídio é proporcionalmente maior em alguns SKUs, a comissão saía NEGATIVA na tabela
-- (ex.: PANP_45_ARN em jul/2026: −R$ 22,54). A M.C. de produto fechava certa, mas a coluna
-- de comissão era ilegível e o take rate por SKU aparecia perto de zero.
--
-- Agora:
--   comissao = comissão + taxa de serviço (BRUTO, o que a SHEIN cobra de fato)
--   subsidio = desconto de promoção bancado pela SHEIN (CRÉDITO, positivo aqui)
--
-- M.C. de produto passa a ser: fat − cmv − comissao − frete − ads + subsidio.
-- Demais canais devolvem subsidio = 0. Nenhum valor de M.C. muda — só a decomposição.

CREATE OR REPLACE FUNCTION public.dre_sku(p_canal text, p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with
  ml_base as (
    select i.pedido_id, i.sku, i.titulo, p.data d, i.item_id,
      i.valor_unitario*i.quantidade fat_i, coalesce(c.custo,0)*i.quantidade cmv_i, i.sale_fee*i.quantidade com_i,
      e.custo_vendedor frete_ped
    from public.ml_pedido_itens i
    join public.ml_pedidos p on p.pedido_id=i.pedido_id
    left join public.ml_custo_produto c on c.sku=i.sku
      and p.data >= c.vigencia_inicio and (c.vigencia_fim is null or p.data < c.vigencia_fim)
    left join public.ml_envios e on e.shipment_id=p.shipping_id
    where p_canal='ml' and to_char(p.data,'YYYY-MM')=p_month and p.status in ('paid','partially_refunded')
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
  ),
  ml_alloc as (
    select sku, titulo, d, fat_i, cmv_i, com_i,
      coalesce(frete_ped,0)*fat_i/nullif(sum(fat_i) over (partition by pedido_id),0) frete_i
    from ml_base
  ),
  ml_agg as (select sku, max(titulo) titulo, d, sum(fat_i) fat, sum(cmv_i) cmv, sum(com_i) comissao, sum(coalesce(frete_i,0)) frete from ml_alloc group by sku, d),
  ml_ads_map as (select item_id, mode() within group (order by sku) sku from public.ml_pedido_itens where item_id is not null group by item_id),
  ml_ads_dia as (select m.sku, a.data d, sum(a.gasto) ads from public.ml_ads_item_diario a join ml_ads_map m on m.item_id=a.item_id where p_canal='ml' and to_char(a.data,'YYYY-MM')=p_month group by m.sku, a.data),
  ml as (select g.sku, g.titulo, g.d, g.fat, g.cmv, g.comissao, g.frete, coalesce(ad.ads,0) ads, 0::numeric subsidio from ml_agg g left join ml_ads_dia ad on ad.sku=g.sku and ad.d=g.d),
  sp_item as (
    select coalesce(nullif(i.model_sku,''), i.item_sku) sku, max(i.item_name) titulo,
      (p.create_time at time zone 'America/Sao_Paulo')::date d,
      sum(i.unit_price*i.quantity) fat, sum(coalesce(c.custo,0)*i.quantity) cmv
    from public.shopee_itens i join public.shopee_pedidos p on p.order_sn=i.order_sn
    left join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.model_sku,''), i.item_sku))
      and (p.create_time at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
      and (c.vigencia_fim is null or (p.create_time at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
    where p_canal='sp' and to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and (p.create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  sp_tot as (
    select coalesce(sum(selling_price-escrow_amount),0) com, nullif(coalesce(sum(selling_price),0),0) fat
    from public.shopee_pedidos
    where p_canal='sp' and to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING') and selling_price is not null
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
  ),
  sp as (select sku, titulo, d, fat, cmv, fat*coalesce((select com/fat from sp_tot),0) comissao, 0::numeric frete, 0::numeric ads, 0::numeric subsidio from sp_item),
  tt_ord as (
    select p.order_id, (p.create_time at time zone 'America/Sao_Paulo')::date d,
      -( coalesce((p.fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'gmv_max_ad_fee_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'smart_promotion_fee_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'tap_shop_ads_commission')::numeric,0)
        +coalesce((p.fin_breakdown->>'cps_shop_ads_commission_tax_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'brand_campaign_fee')::numeric,0)
        +coalesce((p.fin_breakdown->>'category_led_campaign_fee_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'campaign_period_fee_cfp_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'campaign_period_fee_sp_amount')::numeric,0)
        +coalesce((p.fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0)
      ) ads_ord
    from public.tt_pedidos p
    where p_canal='tt' and to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status<>'CANCELLED' and p.fin_filled
      and (p.create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
  ),
  tt_item2 as (
    select i.seller_sku sku, i.product_name titulo, o.d,
      i.sale_price*i.quantity fat_i, coalesce(c.custo,0)*i.quantity cmv_i,
      o.ads_ord * (i.sale_price*i.quantity) / nullif(sum(i.sale_price*i.quantity) over (partition by i.order_id),0) ads_i
    from public.tt_itens i
    join tt_ord o on o.order_id=i.order_id
    left join public.ml_custo_produto c on c.sku=unaccent(coalesce(nullif(i.seller_sku,''),''))
      and o.d >= c.vigencia_inicio and (c.vigencia_fim is null or o.d < c.vigencia_fim)
    where i.line_status<>'CANCELLED'
  ),
  tt_agg as (select sku, max(titulo) titulo, d, sum(fat_i) fat, sum(cmv_i) cmv, sum(coalesce(ads_i,0)) ads from tt_item2 group by sku, d),
  tt_tot as (
    select coalesce(-sum(coalesce(fin_fee_tax,0)),0) fee_tax, coalesce(-sum(coalesce(fin_frete,0)),0) frete, nullif(coalesce(sum(fin_revenue),0),0) fat
    from public.tt_pedidos
    where p_canal='tt' and to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status<>'CANCELLED' and fin_filled
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
  ),
  tt_ads_tot as (select coalesce(sum(ads_ord),0) ads from tt_ord),
  tt as (
    select g.sku, g.titulo, g.d, g.fat, g.cmv,
      g.fat * coalesce((select (fee_tax-(select ads from tt_ads_tot))/fat from tt_tot),0) comissao,
      g.fat * coalesce((select frete/fat from tt_tot),0) frete,
      g.ads,
      0::numeric subsidio
    from tt_agg g
  ),
  az_item as (
    select i.seller_sku sku, max(i.asin) titulo, p.purchase_date::date d,
      sum(i.preco_unitario*i.quantidade) fat, sum(coalesce(c.custo,0)*i.quantidade) cmv
    from public.az_itens i join public.az_pedidos p on p.amazon_order_id=i.amazon_order_id
    left join public.ml_custo_produto c on c.sku=i.seller_sku
      and p.purchase_date >= c.vigencia_inicio
      and (c.vigencia_fim is null or p.purchase_date < c.vigencia_fim)
    where p_canal='az' and to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')
      and p.purchase_date::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  az_tot as (
    select
      coalesce((select sum(coalesce(c.comissao_real,c.comissao_estimada)) from public.az_comissao c join public.az_pedidos p on p.amazon_order_id=c.amazon_order_id where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')),0) com,
      coalesce((select sum(coalesce(f.frete_real,f.frete_estimado)) from public.az_frete f join public.az_pedidos p on p.amazon_order_id=f.amazon_order_id where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')),0) frete,
      nullif(coalesce((select sum(total) from public.az_pedidos where to_char(purchase_date,'YYYY-MM')=p_month and status not in ('Canceled','Pending','Unfulfillable')),0),0) fat
    where p_canal='az'
  ),
  az as (select sku, titulo, d, fat, cmv, fat*coalesce((select com/fat from az_tot),0) comissao, fat*coalesce((select frete/fat from az_tot),0) frete, 0::numeric ads, 0::numeric subsidio from az_item),
  b2b as (
    select i.sku, max(i.descricao) titulo, n.data_emissao::date d, sum(i.valor_total) fat, sum(coalesce(c.custo,0)*i.quantidade) cmv, 0::numeric comissao, 0::numeric frete, 0::numeric ads, 0::numeric subsidio
    from public.b2b_itens i join public.b2b_notas n on n.id=i.nota_id
    left join public.ml_custo_produto c on c.sku=i.sku
      and n.data_emissao >= c.vigencia_inicio
      and (c.vigencia_fim is null or n.data_emissao < c.vigencia_fim)
    where p_canal='b2b' and to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
      and n.data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  sh as (
    select i.seller_sku sku, max(i.goods_title) titulo,
      (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date d,
      sum(coalesce(i.preco_com_desconto,0)) fat, sum(coalesce(c.custo,0)) cmv,
      sum(coalesce(i.comissao,0)+coalesce(i.taxa_servico,0)) comissao,
      0::numeric frete, 0::numeric ads,
      sum((coalesce(i.preco,0)-coalesce(i.cupom,0)-coalesce(i.promo,0)) - coalesce(i.preco_com_desconto,0)) subsidio
    from public.shein_itens i
    join public.shein_pedidos p on p.order_no=i.order_no
    left join public.ml_custo_produto c on c.sku=unaccent(i.seller_sku)
      and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
      and (c.vigencia_fim is null or (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
    where p_canal='sh' and to_char(coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in (6,8,9)
      and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  todos as (select * from ml union all select * from sp union all select * from tt union all select * from az union all select * from b2b union all select * from sh)
  select coalesce(jsonb_agg(jsonb_build_object(
    'sku',sku,'titulo',titulo,'data',to_char(d,'DD/MM'),
    'fat',round(fat,2),'cmv',round(cmv,2),'comissao',round(comissao,2),'frete',round(frete,2),'ads',round(ads,2),
    'subsidio',round(subsidio,2)
  ) order by d, sku),'[]'::jsonb) from todos;
$function$;
