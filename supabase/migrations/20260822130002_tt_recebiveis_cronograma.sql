-- TikTok — recebíveis com DATA derivada (valor segue bruto, FORA do total) · 22/08/2026
--
-- Pedido do Luciano (22/08): cronograma com data em TODAS as plataformas.
-- Fatos medidos (22/08, base `tt_pedidos` após tt_fill_ciclo + tt_fill_statements):
--   • statement do TikTok é DIÁRIO e pago no mesmo dia (payment_time ~3h após);
--   • pedido liquida no statement de (data UTC da entrega + 7): 271/278 exatos,
--     97,7% do VALOR não-otimista (7 outliers liquidaram 2–10 dias DEPOIS);
--   • lag coleta→entrega 60d: p50 3,0d · p90 6,2d · p95 7,0d (371 pedidos);
--   • lag venda→coleta 60d: p50 0,9d · p90 2,0d · p95 2,9d (377 pedidos).
-- Camadas (só a DATA é derivada; o valor é o bruto REAL pago pelo cliente):
--   A. ENTREGUE  → (entrega UTC)::date + 7
--   B. COLETADO  → (coleta UTC)::date + 7 (p95 entrega) + 7 = coleta + 14
--   C. PRÉ/RTS   → (venda UTC)::date + 3 (p95 coleta) + 14 = venda + 17
-- Detector por camada (30d, piso 80%, base mín. 50) contra o statement_time REAL.
-- ⚠️ O VALOR continua FORA DO TOTAL (decisão de 17/08: repasse 84,6%–98,6% do
-- pago). Para informar a decisão, a RPC devolve `repasse_mediano_60d` e o
-- `liquido_indicativo` (bruto × razão mediana) — só na nota, nunca no card.
create or replace function public.tt_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  pend as (
    select order_id, payment_total, create_time, rts_time, collection_time, delivery_time,
           case when delivery_time is not null then 'A'
                when collection_time is not null then 'B'
                else 'C' end as camada
    from tt_pedidos
    where order_status not in ('CANCELLED','UNPAID')
      and not fin_filled
      and payment_total is not null
  ),
  -- Detector: liquidados (statement_time real) nos últimos 30d — derivada >= real?
  acc as (
    select
      count(*) filter (where delivery_time is not null and delivery_time < statement_time) as ped_a,
      coalesce(sum(payment_total) filter (where delivery_time is not null and delivery_time < statement_time), 0) as tot_a,
      coalesce(sum(payment_total) filter (where delivery_time is not null and delivery_time < statement_time
        and (statement_time at time zone 'UTC')::date <= (delivery_time at time zone 'UTC')::date + 7), 0) as ok_a,
      count(*) filter (where collection_time is not null) as ped_b,
      coalesce(sum(payment_total) filter (where collection_time is not null), 0) as tot_b,
      coalesce(sum(payment_total) filter (where collection_time is not null
        and (statement_time at time zone 'UTC')::date <= (collection_time at time zone 'UTC')::date + 14), 0) as ok_b,
      count(*) as ped_c,
      coalesce(sum(payment_total), 0) as tot_c,
      coalesce(sum(payment_total) filter (
        where (statement_time at time zone 'UTC')::date <= (create_time at time zone 'UTC')::date + 17), 0) as ok_c
    from tt_pedidos
    where statement_time is not null and statement_time >= now() - interval '30 days'
      and order_status not in ('CANCELLED','UNPAID') and payment_total is not null
  ),
  gate as (
    select
      ped_a as base_a, case when tot_a > 0 then round((ok_a / tot_a)::numeric, 4) end as acc_a, (ped_a < 50 or (tot_a > 0 and ok_a / tot_a >= 0.80)) as ativo_a,
      ped_b as base_b, case when tot_b > 0 then round((ok_b / tot_b)::numeric, 4) end as acc_b, (ped_b < 50 or (tot_b > 0 and ok_b / tot_b >= 0.80)) as ativo_b,
      ped_c as base_c, case when tot_c > 0 then round((ok_c / tot_c)::numeric, 4) end as acc_c, (ped_c < 50 or (tot_c > 0 and ok_c / tot_c >= 0.80)) as ativo_c
    from acc
  ),
  prev as (
    select p.order_id, p.payment_total as valor, p.camada,
           greatest(case p.camada
             when 'A' then (p.delivery_time at time zone 'UTC')::date + 7
             when 'B' then (p.collection_time at time zone 'UTC')::date + 14
             else          (p.create_time at time zone 'UTC')::date + 17
           end, h.d) as data,
           case p.camada when 'A' then g.ativo_a when 'B' then g.ativo_b else g.ativo_c end as ativa
    from pend p cross join hoje h cross join gate g
  ),
  dias as (select data, round(sum(valor),2) as valor from prev where ativa group by data),
  hist as (
    -- Repasse realizado por mês (só meses com massa mínima). Base: pedidos que JÁ liquidaram.
    select to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM') as mes,
           sum(fin_settlement) / nullif(sum(payment_total),0) * 100 as pct,
           count(*) as n
    from tt_pedidos
    where fin_filled and fin_settlement is not null
      and order_status not in ('CANCELLED','UNPAID')
    group by 1
    having count(*) >= 20
  ),
  razao as (
    select sum(fin_settlement) / nullif(sum(payment_total),0) as r
    from tt_pedidos
    where fin_filled and fin_settlement is not null and order_status not in ('CANCELLED','UNPAID')
      and create_time >= now() - interval '60 days'
  )
  select jsonb_build_object(
    'referencia',   (select d from hoje),
    -- Bruto REAL pago pelo cliente nos pedidos ainda não liquidados.
    'total',        coalesce((select round(sum(payment_total),2) from pend), 0),
    'pedidos',      (select count(*) from pend),
    'mais_antigo',  (select min(create_time)::date from pend),
    -- Faixa histórica do repasse (settlement/pago) — contexto, não projeção.
    'repasse_min',  (select round(min(pct),1) from hist),
    'repasse_max',  (select round(max(pct),1) from hist),
    'meses_base',   (select count(*) from hist),
    'repasse_mediano_60d', (select round(r * 100, 1) from razao),
    'liquido_indicativo',  round((select sum(payment_total) from pend) * (select r from razao), 2),
    'atualizado_em',(select greatest(max(inserted_at), max(ciclo_atualizado_em)) from tt_pedidos),
    'dias',         coalesce((select jsonb_agg(jsonb_build_object('data', data, 'valor', valor) order by data) from dias), '[]'::jsonb),
    'com_data',     coalesce((select round(sum(valor),2) from prev where ativa), 0),
    'pedidos_com_data', (select count(*) from prev where ativa),
    'sem_data',     coalesce((select round(sum(valor),2) from prev where not ativa), 0),
    'pedidos_sem_data', (select count(*) from prev where not ativa),
    'camadas', jsonb_build_object(
       'entregue', jsonb_build_object('valor', coalesce((select round(sum(valor),2) from prev where camada='A' and ativa),0), 'pedidos', (select count(*) from prev where camada='A' and ativa), 'ativa', (select ativo_a from gate), 'acuracia_30d', (select acc_a from gate), 'base', (select base_a from gate)),
       'coletado', jsonb_build_object('valor', coalesce((select round(sum(valor),2) from prev where camada='B' and ativa),0), 'pedidos', (select count(*) from prev where camada='B' and ativa), 'ativa', (select ativo_b from gate), 'acuracia_30d', (select acc_b from gate), 'base', (select base_b from gate)),
       'pre_envio',jsonb_build_object('valor', coalesce((select round(sum(valor),2) from prev where camada='C' and ativa),0), 'pedidos', (select count(*) from prev where camada='C' and ativa), 'ativa', (select ativo_c from gate), 'acuracia_30d', (select acc_c from gate), 'base', (select base_c from gate))
    )
  );
$$;

comment on function public.tt_recebiveis() is
  'Recebíveis TikTok: bruto REAL pago pelo cliente nos pedidos não liquidados (FORA do total — decisão 17/08), agora COM data derivada: entregue → entrega UTC + 7 (statement diário; 97,7% não-otimista), coletado → coleta + 14, pré-envio → venda + 17; detector por camada contra statement_time real. Devolve repasse_mediano_60d/liquido_indicativo só para a nota.';
