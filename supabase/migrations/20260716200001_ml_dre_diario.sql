-- Série diária do ML: faturamento válido + custos DIRETOS por dia (CMV, comissão, frete, ADS bruto).
-- A M.C. diária reconciliada (com rateio dos custos mensais) é montada na camada TS (lib/data/supabase.ts).
CREATE OR REPLACE FUNCTION public.ml_dre_diario(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select p.pedido_id, p.data, p.valor_total, p.shipping_id
    from public.ml_pedidos p
    where to_char(p.data,'YYYY-MM') = p_month
      and p.status in ('paid','partially_refunded')
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
  ),
  fat as (select data, sum(valor_total) v, count(*) q from base group by data),
  cmv as (
    select b.data, sum(c.custo*i.quantidade) v
    from public.ml_pedido_itens i
    join base b on b.pedido_id=i.pedido_id
    join public.ml_custo_produto c on c.sku=i.sku
    group by b.data),
  com as (
    select b.data, sum(i.sale_fee*i.quantidade) v
    from public.ml_pedido_itens i
    join base b on b.pedido_id=i.pedido_id
    group by b.data),
  fr as (
    select b.data, sum(e.custo_vendedor) v
    from base b
    join public.ml_envios e on e.shipment_id=b.shipping_id
    group by b.data),
  ads as (
    select data, sum(gasto) v
    from public.ml_ads_diario
    where to_char(data,'YYYY-MM')=p_month
      and produto in ('product_ads','brand_ads','seguidores')
      and data < (now() at time zone 'America/Sao_Paulo')::date
    group by data)
  select coalesce(jsonb_agg(jsonb_build_object(
    'data', to_char(f.data,'DD/MM'),
    'fat', round(f.v,2),
    'pedidos', f.q,
    'cmv', round(coalesce(cmv.v,0),2),
    'comissao', round(coalesce(com.v,0),2),
    'frete', round(coalesce(fr.v,0),2),
    'ads', round(coalesce(ads.v,0),2)
  ) order by f.data), '[]'::jsonb)
  from fat f
  left join cmv on cmv.data=f.data
  left join com on com.data=f.data
  left join fr on fr.data=f.data
  left join ads on ads.data=f.data;
$function$;
