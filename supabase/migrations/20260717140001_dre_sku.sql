-- DRE por SKU, por canal e por dia: faturamento + CMV (reais) + comissão.
-- Comissão: REAL no ML (sale_fee); nos outros = rateio ∝ faturamento da retenção do canal.
-- MC por SKU (montada no TS) = fat − CMV − comissão (contribuição do PRODUTO, antes de
-- frete/ADS/overhead). Fase 1: sem ADS por SKU. Faturamento é item-level (pode diferir
-- levemente do order-level do canal por IPI/ajustes de pedido).
CREATE OR REPLACE FUNCTION public.dre_sku(p_canal text, p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with
  ml as (
    select i.sku, max(i.titulo) titulo, p.data d,
      sum(i.valor_unitario*i.quantidade) fat,
      sum(coalesce(c.custo,0)*i.quantidade) cmv,
      sum(i.sale_fee*i.quantidade) comissao
    from public.ml_pedido_itens i
    join public.ml_pedidos p on p.pedido_id=i.pedido_id
    left join public.ml_custo_produto c on c.sku=i.sku
    where p_canal='ml' and to_char(p.data,'YYYY-MM')=p_month
      and p.status in ('paid','partially_refunded')
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
    group by i.sku, p.data
  ),
  sp_item as (
    select coalesce(nullif(i.model_sku,''), i.item_sku) sku, max(i.item_name) titulo,
      (p.create_time at time zone 'America/Sao_Paulo')::date d,
      sum(i.unit_price*i.quantity) fat,
      sum(coalesce(c.custo,0)*i.quantity) cmv
    from public.shopee_itens i join public.shopee_pedidos p on p.order_sn=i.order_sn
    left join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.model_sku,''), i.item_sku))
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
  sp as (
    select sku, titulo, d, fat, cmv, fat * coalesce((select com/fat from sp_tot),0) comissao from sp_item
  ),
  tt_item as (
    select i.seller_sku sku, max(i.product_name) titulo,
      (p.create_time at time zone 'America/Sao_Paulo')::date d,
      sum(i.sale_price*i.quantity) fat,
      sum(coalesce(c.custo,0)*i.quantity) cmv
    from public.tt_itens i join public.tt_pedidos p on p.order_id=i.order_id
    left join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.seller_sku,''),''))
    where p_canal='tt' and to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and i.line_status<>'CANCELLED' and p.order_status<>'CANCELLED' and p.fin_filled
      and (p.create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  tt_tot as (
    select coalesce(-sum(coalesce(fin_fee_tax,0)+coalesce(fin_frete,0)),0) com, nullif(coalesce(sum(fin_revenue),0),0) fat
    from public.tt_pedidos
    where p_canal='tt' and to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status<>'CANCELLED' and fin_filled
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
  ),
  tt as (
    select sku, titulo, d, fat, cmv, fat * coalesce((select com/fat from tt_tot),0) comissao from tt_item
  ),
  az_item as (
    select i.seller_sku sku, max(i.asin) titulo, p.purchase_date::date d,
      sum(i.preco_unitario*i.quantidade) fat,
      sum(coalesce(c.custo,0)*i.quantidade) cmv
    from public.az_itens i join public.az_pedidos p on p.amazon_order_id=i.amazon_order_id
    left join public.ml_custo_produto c on c.sku=i.seller_sku
    where p_canal='az' and to_char(p.purchase_date,'YYYY-MM')=p_month
      and p.status not in ('Canceled','Pending','Unfulfillable')
      and p.purchase_date::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  az_tot as (
    select
      coalesce((select sum(coalesce(c.comissao_real,c.comissao_estimada)) from public.az_comissao c join public.az_pedidos p on p.amazon_order_id=c.amazon_order_id where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')),0)
      + coalesce((select sum(coalesce(f.frete_real,f.frete_estimado)) from public.az_frete f join public.az_pedidos p on p.amazon_order_id=f.amazon_order_id where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')),0) com,
      nullif(coalesce((select sum(total) from public.az_pedidos where to_char(purchase_date,'YYYY-MM')=p_month and status not in ('Canceled','Pending','Unfulfillable')),0),0) fat
    where p_canal='az'
  ),
  az as (
    select sku, titulo, d, fat, cmv, fat * coalesce((select com/fat from az_tot),0) comissao from az_item
  ),
  b2b as (
    select i.sku, max(i.descricao) titulo, n.data_emissao::date d,
      sum(i.valor_total) fat,
      sum(coalesce(c.custo,0)*i.quantidade) cmv,
      0::numeric comissao
    from public.b2b_itens i join public.b2b_notas n on n.id=i.nota_id
    left join public.ml_custo_produto c on c.sku=i.sku
    where p_canal='b2b' and to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
      and n.data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  todos as (
    select * from ml union all select * from sp union all select * from tt union all select * from az union all select * from b2b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'sku',sku,'titulo',titulo,'data',to_char(d,'DD/MM'),
    'fat',round(fat,2),'cmv',round(cmv,2),'comissao',round(comissao,2)
  ) order by d, sku),'[]'::jsonb) from todos;
$function$;
