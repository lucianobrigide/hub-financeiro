-- ═══════════════════════════════════════════════════════════════════════════
-- TikTok: M.C. PROJETADA (decisão do Luciano, 12/08/2026)
-- Substitui a política "piso de cobertura / nada estimado" (28/07) PARA O TIKTOK:
-- com afiliados+ads dominando o mix, esperar o settlement (só pós-entrega)
-- inflava a M.C. do mês corrente em todo dia de venda forte.
-- Novo desenho: deduções reais nos pedidos liquidados + PROVISÃO por take-rate
-- móvel nos demais; a provisão morre pedido a pedido quando o statement chega.
-- Shopee segue na regra antiga (escrow chega no READY_TO_SHIP, sem lag).
-- Espelho das migrações aplicadas via MCP em 12/08/2026.
-- ═══════════════════════════════════════════════════════════════════════════

-- Config da provisão (seeds e regras de medição)
create table if not exists public.tt_provisao_config (
  id int primary key default 1 check (id = 1),
  afiliado_seed_pct numeric not null default 0,   -- fração da receita usada até haver medição do mix novo
  ads_seed_pct numeric not null default 0,        -- idem GMV Max (12/08: Luciano decidiu NÃO provisionar ads; fica 0 até conectar a Business API)
  mix_cutoff date not null default '2026-08-01',  -- início do mix afiliados+ads
  min_pedidos_medida int not null default 20,     -- mínimo de liquidados pós-cutoff para trocar seed -> medido
  updated_at timestamptz not null default now()
);
alter table public.tt_provisao_config enable row level security;
insert into public.tt_provisao_config (id) values (1) on conflict do nothing;

-- Comissão de afiliado real por pedido (Affiliate API, conhecida em D+0)
alter table public.tt_pedidos add column if not exists aff_commission numeric;
alter table public.tt_pedidos add column if not exists aff_filled boolean not null default false;
alter table public.tt_pedidos add column if not exists aff_attempts int not null default 0;

-- Gasto diário de ads (GMV Max via Business API; mesmo padrão azads_gastos/shopee_ads_diario)
create table if not exists public.tt_ads_diario (
  data date primary key,
  cost numeric not null default 0,
  orders int,
  gmv numeric,
  fonte text not null default 'gmv_max',
  updated_at timestamptz not null default now()
);
alter table public.tt_ads_diario enable row level security;
comment on table public.tt_ads_diario is 'Gasto diario TikTok GMV Max (Business API gmvMaxReportGet). Enquanto vazio, o DRE provisiona ads por % movel sobre liquidados; quando preenchido, o dia usa o custo real daqui e as chaves gmv_max do settlement sao EXCLUIDAS das deducoes para nao contar em dobro.';

-- Take-rates medidos sobre pedidos liquidados (janela móvel).
-- Plataforma (comissão/sfp/fee_item/frete/outras): janela inteira — taxas contratuais estáveis.
-- Afiliado/Ads: só liquidados criados >= mix_cutoff (mix novo); antes de min_pedidos_medida usa o seed.
create or replace function public.tt_take_rates(p_days integer default 60)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
with cfg as (select * from tt_provisao_config where id = 1),
liq as (
  select p.order_id, p.create_time, coalesce(p.fin_revenue,0) as rev,
    coalesce((p.fin_breakdown->>'platform_commission_amount')::numeric,0) as comissao,
    coalesce((p.fin_breakdown->>'sfp_service_fee_amount')::numeric,0)     as sfp,
    coalesce((p.fin_breakdown->>'fee_per_item_sold_amount')::numeric,0)   as fee_item,
    coalesce((p.fin_breakdown->>'affiliate_commission_amount')::numeric,0) as afiliado,
    ( coalesce((p.fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
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
    + coalesce((p.fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0)
    ) as ads,
    coalesce(p.fin_frete,0)   as frete,
    coalesce(p.fin_fee_tax,0) as fee_tax
  from tt_pedidos p
  where p.fin_filled and p.order_status <> 'CANCELLED'
    and p.create_time >= now() - make_interval(days => p_days)
),
itens as (
  select i.order_id, sum(i.quantity) as q
  from tt_itens i where i.line_status <> 'CANCELLED'
  group by 1
),
base as (select l.*, coalesce(it.q, 1) as itens from liq l left join itens it using (order_id)),
agg as (
  select coalesce(sum(rev),0) rev, coalesce(sum(itens),0) itens, count(*) n,
         -sum(comissao) comissao, -sum(sfp) sfp, -sum(fee_item) fee_item, -sum(frete) frete,
         -sum(fee_tax - comissao - sfp - fee_item - afiliado - ads) outras
  from base
),
novo as (
  select count(*) n, coalesce(sum(b.rev),0) rev, -sum(b.afiliado) afiliado, -sum(b.ads) ads
  from base b, cfg where b.create_time >= cfg.mix_cutoff
)
select jsonb_build_object(
  'comissao_pct', coalesce(round(agg.comissao / nullif(agg.rev,0), 5), 0),
  'sfp_pct',      coalesce(round(agg.sfp      / nullif(agg.rev,0), 5), 0),
  'fee_item',     coalesce(round(agg.fee_item / nullif(agg.itens,0), 4), 0),
  'frete_pct',    coalesce(round(agg.frete    / nullif(agg.rev,0), 5), 0),
  'outras_pct',   coalesce(round(agg.outras   / nullif(agg.rev,0), 5), 0),
  'afiliado_pct', case when novo.n >= cfg.min_pedidos_medida
                       then coalesce(round(novo.afiliado / nullif(novo.rev,0), 5), 0)
                       else cfg.afiliado_seed_pct end,
  'ads_pct',      case when novo.n >= cfg.min_pedidos_medida
                       then coalesce(round(novo.ads / nullif(novo.rev,0), 5), 0)
                       else cfg.ads_seed_pct end,
  'afiliado_fonte', case when novo.n >= cfg.min_pedidos_medida then 'medido' else 'seed' end,
  'ads_fonte',      case when novo.n >= cfg.min_pedidos_medida then 'medido' else 'seed' end,
  'pedidos_janela', agg.n,
  'pedidos_mix_novo', novo.n
) from agg, novo, cfg;
$function$;

-- Deduções TikTok = real (liquidados) + provisão (aguardando settlement).
-- Substituição automática por pedido quando fin_filled vira true.
-- Afiliado: aff_commission (Affiliate API, D+0) quando disponível; senão % do take-rate.
-- Ads: tt_ads_diario (real) > settlement+provisão; exclui gmv_max do settlement se tt_ads_diario tem dados.
create or replace function public.tt_deducoes_projetado(p_month text)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
with tr as (select public.tt_take_rates(60) as r),
ads_dia as (
  select coalesce(sum(cost),0) as custo, count(*) as dias
  from tt_ads_diario where to_char(data,'YYYY-MM') = p_month
),
ped as (
  select p.*, coalesce(it.q,1) as itens
  from tt_pedidos p
  left join (select order_id, sum(quantity) q from tt_itens where line_status <> 'CANCELLED' group by 1) it
    using (order_id)
  where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM') = p_month
    and p.order_status not in ('CANCELLED','UNPAID')
),
real_liq as (
  select
    coalesce(-sum(coalesce((fin_breakdown->>'platform_commission_amount')::numeric,0)),0) as comissao,
    coalesce(-sum(coalesce((fin_breakdown->>'affiliate_commission_amount')::numeric,0)),0) as afiliados,
    coalesce(-sum( coalesce((fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
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
        ),0) as ads,
    coalesce(-sum(coalesce(fin_frete,0)),0) as frete,
    coalesce(-sum(coalesce(fin_fee_tax,0)),0) as fee_tax_total,
    count(*) as pedidos,
    coalesce(sum(coalesce(fin_revenue, payment_total)),0) as receita
  from ped where fin_filled
),
prov as (
  select
    coalesce(sum((tr.r->>'comissao_pct')::numeric * payment_total),0) as comissao,
    coalesce(sum(case when aff_filled then coalesce(aff_commission,0)
                      else (tr.r->>'afiliado_pct')::numeric * payment_total end),0) as afiliados,
    coalesce(sum((tr.r->>'ads_pct')::numeric * payment_total),0) as ads,
    coalesce(sum((tr.r->>'frete_pct')::numeric * payment_total),0) as frete,
    coalesce(sum( (tr.r->>'sfp_pct')::numeric * payment_total
                + (tr.r->>'fee_item')::numeric * itens
                + (tr.r->>'outras_pct')::numeric * payment_total),0) as taxas,
    count(*) as pedidos,
    coalesce(sum(payment_total),0) as receita,
    count(*) filter (where aff_filled) as pedidos_aff_real
  from ped, tr where not fin_filled
),
m as (
  select
    rl.comissao + pv.comissao as comissao,
    rl.afiliados + pv.afiliados as afiliados,
    case when ad.dias > 0 then ad.custo else rl.ads + pv.ads end as ads,
    rl.frete + pv.frete as frete,
    (rl.fee_tax_total - rl.comissao - rl.afiliados - rl.ads) + pv.taxas as taxas,
    rl.pedidos as pedidos_liq, pv.pedidos as pedidos_prov,
    rl.receita as receita_liq, pv.receita as receita_prov,
    pv.pedidos_aff_real,
    ad.dias as ads_dias_reais
  from real_liq rl, prov pv, ads_dia ad
)
select jsonb_build_object(
  'comissao',  round(comissao, 2),
  'afiliados', round(afiliados, 2),
  'ads',       round(ads, 2),
  'frete',     round(frete, 2),
  'taxas',     round(taxas, 2),
  'pedidos',   pedidos_liq + pedidos_prov,
  'pedidos_liquidados',  pedidos_liq,
  'pedidos_provisionados', pedidos_prov,
  'pedidos_afiliado_real', pedidos_aff_real,
  'pct_liquidado', coalesce(round(receita_liq / nullif(receita_liq + receita_prov, 0) * 100, 1), 0),
  'ads_fonte', case when ads_dias_reais > 0 then 'tt_ads_diario' else 'settlement+provisao' end,
  'take_rates', (select r from tr)
) from m;
$function$;

-- Fix: com 0 pedidos liquidados no mês, refund_net era NULL e derrubava
-- faturamento_bruto para 0/NULL no card ("sem dados").
create or replace function public.tt_faturamento(p_month text)
returns jsonb
language sql stable security definer
as $function$
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
    'faturamento_bruto',   coalesce(revenue,0) - coalesce(refund_net,0),
    'devolucoes',          -coalesce(refund_net,0),
    'faturamento_liquido', coalesce(revenue, 0),
    'liquido_liquidado',   coalesce(revenue_liq, 0),
    'total_pedidos',       coalesce(pedidos, 0),
    'pedidos_liquidados',  coalesce(pedidos_liq, 0),
    'pago_total',          coalesce(pago_total, 0),
    'pago_liquidado',      coalesce(pago_liq, 0),
    'settlement',          coalesce(settlement, 0)
  ) FROM b;
$function$;
