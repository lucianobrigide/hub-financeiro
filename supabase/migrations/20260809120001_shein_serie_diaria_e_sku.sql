-- SHEIN no grafico diario e no DRE por SKU (card igual aos demais canais).
--
-- 1) dre_diario_canais: ramo 'sh' — fat = Σ produto_total (status NOT IN 6/8/9,
--    competencia payment_time BRT, fallback order_time; exclui o dia corrente,
--    padrao dos demais canais). Deducoes REAIS do pedido (comissao + taxa de
--    servico + cupons/promos) entram na coluna 'comissao' (mesma tecnica da
--    Shopee, que usa a coluna para "bruta - repasse"); frete/ads = 0 (nao
--    existem na SHEIN). CMV por item (1 unidade por goodsId) com vigencia
--    ancorada na competencia — padrao shein_cmv.
--
-- 2) dre_sku: ramo 'sh' — valores 100% REAIS por item, sem rateio: validado
--    em 09/08/2026 que Σ itens = pedido centavo a centavo no mes de agosto
--    (preco 53.081,90 = produto_total; cupom+promo, comissao e taxa idem).
--    fat = preco de tabela do item (Σ = bruta do card); comissao = comissao +
--    taxa de servico + cupom + promo do ITEM.
--
-- Nenhum numero estimado (REGRA DURA): tudo vem do order-detail da API.

create or replace function public.dre_diario_canais(p_month text)
 returns jsonb
 language sql
 security definer
 set search_path to 'public'
as $function$
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
  tt_ped as (
    select (create_time at time zone 'America/Sao_Paulo')::date d,
           sum(case when fin_filled then coalesce(fin_revenue,0) else coalesce(payment_total,0) end) fat,
           -sum(coalesce(fin_fee_tax,0)) taxas, -sum(coalesce(fin_frete,0)) frete
    from public.tt_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status not in ('CANCELLED','UNPAID')
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
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
      coalesce(tt_cmv.cmv,0) cmv, tt_ped.taxas comissao, tt_ped.frete frete, 0::numeric ads
    from tt_ped left join tt_cmv on tt_cmv.d=tt_ped.d),
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
    select (coalesce(payment_time, order_time) at time zone 'America/Sao_Paulo')::date d,
           sum(produto_total) fat,
           sum(coalesce(comissao,0)+coalesce(taxa_servico,0)+coalesce(desconto_loja,0)+coalesce(desconto_promo,0)) ded
    from public.shein_pedidos
    where to_char(coalesce(payment_time, order_time) at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status not in (6,8,9)
      and (coalesce(payment_time, order_time) at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
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

create or replace function public.dre_sku(p_canal text, p_month text)
 returns jsonb
 language sql
 security definer
 set search_path to 'public'
as $function$
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
  ml as (select g.sku, g.titulo, g.d, g.fat, g.cmv, g.comissao, g.frete, coalesce(ad.ads,0) ads from ml_agg g left join ml_ads_dia ad on ad.sku=g.sku and ad.d=g.d),
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
  sp as (select sku, titulo, d, fat, cmv, fat*coalesce((select com/fat from sp_tot),0) comissao, 0::numeric frete, 0::numeric ads from sp_item),
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
      g.ads
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
  az as (select sku, titulo, d, fat, cmv, fat*coalesce((select com/fat from az_tot),0) comissao, fat*coalesce((select frete/fat from az_tot),0) frete, 0::numeric ads from az_item),
  b2b as (
    select i.sku, max(i.descricao) titulo, n.data_emissao::date d, sum(i.valor_total) fat, sum(coalesce(c.custo,0)*i.quantidade) cmv, 0::numeric comissao, 0::numeric frete, 0::numeric ads
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
      sum(i.preco) fat, sum(coalesce(c.custo,0)) cmv,
      sum(coalesce(i.comissao,0)+coalesce(i.taxa_servico,0)+coalesce(i.cupom,0)+coalesce(i.promo,0)) comissao,
      0::numeric frete, 0::numeric ads
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
    'fat',round(fat,2),'cmv',round(cmv,2),'comissao',round(comissao,2),'frete',round(frete,2),'ads',round(ads,2)
  ) order by d, sku),'[]'::jsonb) from todos;
$function$;
