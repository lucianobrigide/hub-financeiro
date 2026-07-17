-- Faturamento + custos DIRETOS por dia, por canal (Shopee/TikTok/Amazon/B2B).
-- Substitui o uso de vendas_diarias_canais (que só trazia faturamento).
-- A M.C. diária reconciliada (rateio do resíduo mensal: DIFAL/devoluções por ciclo)
-- é montada na camada TS (lib/data/supabase.ts). TikTok/Amazon/B2B fecham exatos;
-- Shopee tem resíduo = DIFAL + custo devoluções (rateado).
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
      (sp_ped.fat - sp_ped.repasse) + coalesce(sp_ads.ads,0) + coalesce(sp_cmv.cmv,0) custos
    from sp_ped left join sp_cmv on sp_cmv.d=sp_ped.d left join sp_ads on sp_ads.d=sp_ped.d),
  tt_ped as (
    select (create_time at time zone 'America/Sao_Paulo')::date d,
           sum(fin_revenue) fat, -sum(coalesce(fin_fee_tax,0)+coalesce(fin_frete,0)) feefrete
    from public.tt_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status<>'CANCELLED' and fin_filled
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  tt_cmv as (
    select (p.create_time at time zone 'America/Sao_Paulo')::date d, sum(c.custo*i.quantity) cmv
    from public.tt_itens i join public.tt_pedidos p on p.order_id=i.order_id
    join public.ml_custo_produto c on c.sku = unaccent(coalesce(nullif(i.seller_sku,''),''))
    where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and i.line_status<>'CANCELLED' and p.order_status<>'CANCELLED' and p.fin_filled
    group by 1),
  tt as (
    select 'tt'::text canal, tt_ped.d, tt_ped.fat, tt_ped.feefrete + coalesce(tt_cmv.cmv,0) custos
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
    where to_char(p.purchase_date,'YYYY-MM')=p_month and p.status not in ('Canceled','Pending','Unfulfillable')
    group by 1),
  az as (
    select 'az'::text canal, az_ped.d, az_ped.fat,
      coalesce(az_com.com,0)+coalesce(az_fr.fr,0)+coalesce(az_cmv.cmv,0) custos
    from az_ped left join az_com on az_com.d=az_ped.d left join az_fr on az_fr.d=az_ped.d left join az_cmv on az_cmv.d=az_ped.d),
  b2b_ped as (
    select n.data_emissao::date d, sum(n.valor_total) fat from public.b2b_notas n
    where to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
      and n.data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1),
  b2b_cmv as (
    select n.data_emissao::date d, sum(i.quantidade*c.custo) cmv
    from public.b2b_itens i join public.b2b_notas n on n.id=i.nota_id
    join public.ml_custo_produto c on c.sku=i.sku
    where to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
    group by 1),
  b2b as (
    select 'b2b'::text canal, b2b_ped.d, b2b_ped.fat, coalesce(b2b_cmv.cmv,0) custos
    from b2b_ped left join b2b_cmv on b2b_cmv.d=b2b_ped.d),
  todos as (select * from sp union all select * from tt union all select * from az union all select * from b2b)
  select coalesce(jsonb_agg(jsonb_build_object(
    'canal',canal,'data',to_char(d,'DD/MM'),'fat',round(fat,2),'custos',round(custos,2)
  ) order by d, canal),'[]'::jsonb) from todos;
$function$;
