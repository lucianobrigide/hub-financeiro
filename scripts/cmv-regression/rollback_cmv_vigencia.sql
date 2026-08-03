-- ROLLBACK da migration 20260803190001_cmv_vigencia (CMV com vigência temporal).
-- Restaura o estado pré-migration: tabela ml_custo_produto com custo único por SKU
-- (PK = sku) e as 9 RPCs originais (capturadas do banco vivo via pg_get_functiondef
-- em 03/08/2026, ANTES da migration).
--
-- ATENÇÃO: descarta qualquer linha de custo criada após a migration
-- (vigencia_inicio <> '2000-01-01') — o snapshot de custos volta a ser o de 03/08/2026.
-- Rode também: node scripts/cmv-regression/snapshot.mjs + diff.mjs para conferir.

begin;

-- 1 · Fluxo de alteração e trigger
drop function if exists public.cmv_alterar_custo(text, numeric, date, text, text);
drop trigger if exists ml_custo_produto_custo_imutavel on public.ml_custo_produto;
drop function if exists public.ml_custo_produto_guard();

-- 2 · Dados: descarta linhas pós-migration e reabre as originais
delete from public.ml_custo_produto where vigencia_inicio <> '2000-01-01';
update public.ml_custo_produto set vigencia_fim = null where vigencia_fim is not null;

-- 3 · Constraints e colunas
alter table public.ml_custo_produto drop constraint ml_custo_produto_sem_sobreposicao;
alter table public.ml_custo_produto drop constraint ml_custo_produto_vigencia_valida;
alter table public.ml_custo_produto drop constraint ml_custo_produto_pkey;
alter table public.ml_custo_produto drop column vigencia_inicio, drop column vigencia_fim;
alter table public.ml_custo_produto add constraint ml_custo_produto_pkey primary key (sku);

comment on table public.ml_custo_produto is
  'De-para variante(SKU vendido) -> modelo -> CMV. Custo por modelo vindo de PRODUTOS.xlsx. '
  'origem: confirmado (dono validou variante), exato (SKU vendido = SKU planilha), '
  'proposto-prefixo (casou por prefixo, dono validou em jun/2026).';

drop extension if exists btree_gist;

-- 4 · RPCs originais (verbatim do banco vivo, pré-migration) ------------------------

CREATE OR REPLACE FUNCTION public.ml_cmv(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'cmv_total_mes',
    coalesce((
      select round(sum(c.custo * i.quantidade), 2)
      from public.ml_pedido_itens i
      join public.ml_pedidos p on p.pedido_id = i.pedido_id
      join public.ml_custo_produto c on c.sku = i.sku
      where to_char(p.data, 'YYYY-MM') = p_month
        and p.status in ('paid', 'partially_refunded')
        and p.data < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$function$;

CREATE OR REPLACE FUNCTION public.ml_cmv_cobertura(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select i.sku, i.quantidade, i.valor_unitario, c.custo
    from public.ml_pedido_itens i
    join public.ml_pedidos p on p.pedido_id = i.pedido_id
    left join public.ml_custo_produto c on c.sku = i.sku
    where to_char(p.data, 'YYYY-MM') = p_month
      and p.status in ('paid', 'partially_refunded')
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
  )
  select jsonb_build_object(
    'itens', count(*),
    'itens_sem_custo', count(*) filter (where custo is null),
    'skus_sem_custo', count(distinct sku) filter (where custo is null),
    'cobertura_pct', round(100.0 * count(*) filter (where custo is not null) / nullif(count(*), 0), 2),
    'faturamento_descoberto', coalesce(round(sum(valor_unitario * quantidade) filter (where custo is null), 2), 0),
    'skus', coalesce((
      select jsonb_agg(distinct jsonb_build_object('sku', sku) )
      from base where custo is null
    ), '[]'::jsonb)
  )
  from base;
$function$;

CREATE OR REPLACE FUNCTION public.sp_cmv(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'cmv_total',       COALESCE(SUM(c.custo * i.quantity), 0),
    'cmv_com_escrow',  COALESCE(SUM(c.custo * i.quantity) FILTER (WHERE p.escrow_adjusted IS NOT NULL), 0),
    'itens_com_custo', COUNT(*) FILTER (WHERE c.custo IS NOT NULL),
    'itens_total',     COUNT(*)
  )
  FROM public.shopee_itens i
  JOIN public.shopee_pedidos p ON p.order_sn = i.order_sn
  LEFT JOIN public.ml_custo_produto c
    ON c.sku = unaccent(COALESCE(NULLIF(i.model_sku, ''), i.item_sku))
  WHERE to_char(p.create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND p.order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND p.selling_price IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.tt_cmv(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
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

CREATE OR REPLACE FUNCTION public.az_cmv(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'cmv_total', COALESCE(SUM(c.custo * i.quantidade), 0),
    'itens_com_custo', COUNT(*) FILTER (WHERE c.custo IS NOT NULL),
    'itens_total', COUNT(*)
  )
  FROM public.az_itens i
  JOIN public.az_pedidos p ON p.amazon_order_id = i.amazon_order_id
  LEFT JOIN public.ml_custo_produto c ON c.sku = i.seller_sku
  WHERE to_char(p.purchase_date, 'YYYY-MM') = p_month
    AND p.status NOT IN ('Canceled', 'Pending', 'Unfulfillable');
$function$;

CREATE OR REPLACE FUNCTION public.b2b_cmv(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'cmv_total', coalesce(sum(i.quantidade * c.custo), 0),
    'itens_com_custo', count(c.sku),
    'itens_total', count(i.sku)
  )
  FROM b2b_itens i
  JOIN b2b_notas n ON n.id = i.nota_id
  LEFT JOIN ml_custo_produto c ON c.sku = i.sku
  WHERE to_char(n.data_emissao, 'YYYY-MM') = p_month
    AND n.situacao IN (6, 7);
$function$;

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
    where to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
    group by 1),
  b2b as (
    select 'b2b'::text canal, b2b_ped.d, b2b_ped.fat,
      coalesce(b2b_cmv.cmv,0) cmv, 0::numeric comissao, 0::numeric frete, 0::numeric ads
    from b2b_ped left join b2b_cmv on b2b_cmv.d=b2b_ped.d),
  todos as (select * from sp union all select * from tt union all select * from az union all select * from b2b)
  select coalesce(jsonb_agg(jsonb_build_object(
    'canal',canal,'data',to_char(d,'DD/MM'),
    'fat',round(fat,2),'cmv',round(cmv,2),'comissao',round(comissao,2),
    'frete',round(frete,2),'ads',round(ads,2)
  ) order by d, canal),'[]'::jsonb) from todos;
$function$;

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
    where p_canal='b2b' and to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
      and n.data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  todos as (select * from ml union all select * from sp union all select * from tt union all select * from az union all select * from b2b)
  select coalesce(jsonb_agg(jsonb_build_object(
    'sku',sku,'titulo',titulo,'data',to_char(d,'DD/MM'),
    'fat',round(fat,2),'cmv',round(cmv,2),'comissao',round(comissao,2),'frete',round(frete,2),'ads',round(ads,2)
  ) order by d, sku),'[]'::jsonb) from todos;
$function$;

commit;
