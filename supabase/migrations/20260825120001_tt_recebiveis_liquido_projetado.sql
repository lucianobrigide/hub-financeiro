-- TikTok recebíveis: valor LÍQUIDO PROJETADO (Opção B — decisão do Luciano 25/08/2026).
--
-- Até aqui o card mostrava o BRUTO pago pelo cliente e ficava FORA do total
-- consolidado (decisão de 17/08: o repasse variava 73%–101% do pago e não havia
-- data). A data foi resolvida em 22/08 (statement diário de entrega+7). Agora o
-- VALOR entra como projeção auto-corrigida:
--
--   líquido projetado = bruto × razão móvel 60d (Σ settlement / Σ pago dos
--   pedidos LIQUIDADOS nos últimos 60 dias, recalculada a cada leitura,
--   capada em 1.0 a favor do caixa)
--
-- A projeção morre pedido a pedido: quando o statement real chega, fin_filled
-- vira true e o pedido sai do conjunto pendente — nada projetado sobrevive ao
-- dado real. Trava de honestidade: com menos de 50 liquidados na janela de 60d
-- (ou razão nula) a projeção NÃO liga — `projetado=false`, valores voltam ao
-- bruto e o provider devolve o card para fora do total, como era.
--
-- Campos novos no retorno: projetado, bruto, base_razao. `total`, `dias`,
-- `com_data`, `sem_data` e `camadas` passam a sair na escala projetada quando
-- `projetado=true` (Σ dias = com_data por construção).

create or replace function public.tt_recebiveis()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
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
  razao as (
    select least(sum(fin_settlement) / nullif(sum(payment_total), 0), 1.0) as r,
           count(*) as base
    from tt_pedidos
    where fin_filled and fin_settlement is not null and order_status not in ('CANCELLED','UNPAID')
      and create_time >= now() - interval '60 days'
  ),
  proj as (
    select (r is not null and base >= 50) as ativo,
           case when r is not null and base >= 50 then r else 1 end as mult,
           r, base
    from razao
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
  dias as (
    select data, round(sum(valor * pr.mult), 2) as valor
    from prev cross join proj pr
    where ativa
    group by data
  ),
  semdata as (
    select coalesce(round(sum(p.valor * pr.mult), 2), 0) as v
    from prev p cross join proj pr
    where not p.ativa
  ),
  hist as (
    select to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM') as mes,
           sum(fin_settlement) / nullif(sum(payment_total),0) * 100 as pct,
           count(*) as n
    from tt_pedidos
    where fin_filled and fin_settlement is not null
      and order_status not in ('CANCELLED','UNPAID')
    group by 1
    having count(*) >= 20
  )
  select jsonb_build_object(
    'referencia',   (select d from hoje),
    'projetado',    (select ativo from proj),
    'bruto',        coalesce((select round(sum(payment_total),2) from pend), 0),
    -- total = com_data + sem_data por construção (Σ dias + valorSemData = total na UI, centavo a centavo)
    'total',        coalesce((select sum(valor) from dias), 0) + (select v from semdata),
    'pedidos',      (select count(*) from pend),
    'mais_antigo',  (select min(create_time)::date from pend),
    'repasse_min',  (select round(min(pct),1) from hist),
    'repasse_max',  (select round(max(pct),1) from hist),
    'meses_base',   (select count(*) from hist),
    'repasse_mediano_60d', (select round(r * 100, 1) from razao),
    'base_razao',   (select base from razao),
    'liquido_indicativo',  round((select sum(payment_total) from pend) * (select r from razao), 2),
    'atualizado_em',(select greatest(max(inserted_at), max(ciclo_atualizado_em)) from tt_pedidos),
    'dias',         coalesce((select jsonb_agg(jsonb_build_object('data', data, 'valor', valor) order by data) from dias), '[]'::jsonb),
    'com_data',     coalesce((select sum(valor) from dias), 0),
    'pedidos_com_data', (select count(*) from prev where ativa),
    'sem_data',     (select v from semdata),
    'pedidos_sem_data', (select count(*) from prev where not ativa),
    'camadas', jsonb_build_object(
       'entregue', jsonb_build_object('valor', coalesce((select round(sum(p.valor * pr.mult),2) from prev p cross join proj pr where p.camada='A' and p.ativa),0), 'pedidos', (select count(*) from prev where camada='A' and ativa), 'ativa', (select ativo_a from gate), 'acuracia_30d', (select acc_a from gate), 'base', (select base_a from gate)),
       'coletado', jsonb_build_object('valor', coalesce((select round(sum(p.valor * pr.mult),2) from prev p cross join proj pr where p.camada='B' and p.ativa),0), 'pedidos', (select count(*) from prev where camada='B' and ativa), 'ativa', (select ativo_b from gate), 'acuracia_30d', (select acc_b from gate), 'base', (select base_b from gate)),
       'pre_envio',jsonb_build_object('valor', coalesce((select round(sum(p.valor * pr.mult),2) from prev p cross join proj pr where p.camada='C' and p.ativa),0), 'pedidos', (select count(*) from prev where camada='C' and ativa), 'ativa', (select ativo_c from gate), 'acuracia_30d', (select acc_c from gate), 'base', (select base_c from gate))
    )
  );
$function$;

comment on function public.tt_recebiveis() is
'Recebíveis TikTok com valor LÍQUIDO PROJETADO (Opção B, Luciano 25/08/2026): bruto × razão móvel 60d (settlement/pago dos liquidados, capada em 1.0), auto-corrigida pedido a pedido quando o statement real chega. projetado=false (base <50 liquidados em 60d) devolve o bruto e o card volta a ficar fora do total. Data derivada do statement diário (22/08): entregue→entrega+7 · coletado→coleta+14 · pré-envio→venda+17, detector por camada (30d, piso 80%).';
