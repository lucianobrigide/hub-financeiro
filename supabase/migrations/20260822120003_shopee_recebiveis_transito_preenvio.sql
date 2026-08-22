-- Shopee — recebíveis: data DERIVADA também para em trânsito e pré-envio · 22/08/2026
--
-- Pedido do Luciano (22/08): cronograma com data em TODAS as plataformas. Isso
-- reabre as Camadas B/C rejeitadas em 19/08 (que exigiam estimativa NOSSA de prazo
-- de entrega, já que a Shopee não manda `edt_*` nesta loja). A diferença agora: a
-- estimativa é MEDIDA na própria operação, com teto a favor do caixa e backtest
-- contra o crédito REAL da carteira, e cada camada tem seu detector de acurácia.
--
-- Camadas (valor = escrow real da API em todas; só a DATA é derivada):
--   A. COMPLETED → hoje; ENTREGUE → entrega + 8d (régua de 19/08, acurácia 98-99%).
--   B. EM TRÂNSITO (coleta feita, sem entrega) → coleta + 15d
--      = entrega prevista (coleta + 7d: lag coleta→entrega 60d p50 2,8d · p90 5,3d ·
--        96,2% em ≤7d, 942 pedidos) + 8d da Camada A.
--      Backtest 30d: 98,5% do VALOR creditado até coleta+15d (3.948 pedidos).
--   C. PRÉ-ENVIO (sem coleta) → venda + 18d
--      = coleta prevista (venda + 3d: lag venda→coleta p90 2,1d · p95 2,8d) + 15d.
--      Backtest 30d: 99,0% do VALOR creditado até venda+18d.
-- Cada camada é gated pelo próprio detector (30d, piso 80%, base mín. 50): se
-- driftar, SÓ aquela camada volta para "sem data" — as outras seguem.
create or replace function public.shopee_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with cobertura as (
    select min(create_time) as desde, max(create_time) as ate from shopee_wallet
  ),
  saldo as (
    select current_balance from shopee_wallet order by create_time desc, transaction_id desc limit 1
  ),
  mov as (
    select order_sn,
           bool_or(transaction_type = 'ESCROW_VERIFIED_ADD')             as teve_credito,
           bool_or(transaction_type = 'ESCROW_VERIFIED_MINUS')           as teve_debito,
           bool_or(transaction_type = 'RETURN_COMPENSATION_SERVICE_ADD'
                   -- compensação de extravio: MONEY_IN com tipo vazio
                   or (coalesce(transaction_type,'') = '' and money_flow = 'MONEY_IN')) as teve_compensacao
    from shopee_wallet
    where order_sn is not null and order_sn <> ''
    group by order_sn
  ),
  hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  base as (
    select p.order_sn,
           coalesce(p.escrow_adjusted, p.escrow_amount) as valor,
           p.order_status,
           p.create_time,
           p.pickup_done_time,
           p.delivered_time,
           (p.order_status = 'TO_RETURN'
            or coalesce(m.teve_compensacao, false)
            or coalesce(m.teve_debito, false)) as fora,
           case
             when p.order_status = 'COMPLETED' or p.delivered_time is not null then 'A'
             when p.pickup_done_time is not null then 'B'
             else 'C'
           end as camada
    from shopee_pedidos p
    left join mov m on m.order_sn = p.order_sn
    cross join cobertura c
    where p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and coalesce(p.escrow_adjusted, p.escrow_amount) is not null
      and p.create_time >= c.desde
      and coalesce(m.teve_credito, false) = false
  ),
  cred as (
    select w.order_sn, min(w.create_time) as creditado_em, sum(w.amount) as valor
    from shopee_wallet w
    where w.transaction_type = 'ESCROW_VERIFIED_ADD' and coalesce(w.order_sn,'') <> ''
    group by w.order_sn
  ),
  -- Detectores: pedidos creditados nos últimos 30d — a data derivada de cada camada
  -- foi <= data real do crédito? (% do VALOR)
  acc as (
    select
      count(*) filter (where p.delivered_time is not null and p.delivered_time < c.creditado_em) as ped_a,
      coalesce(sum(c.valor) filter (where p.delivered_time is not null and p.delivered_time < c.creditado_em), 0) as tot_a,
      coalesce(sum(c.valor) filter (where p.delivered_time is not null and p.delivered_time < c.creditado_em
        and (c.creditado_em at time zone 'America/Sao_Paulo')::date <= (p.delivered_time at time zone 'America/Sao_Paulo')::date + 9), 0) as ok_a,
      count(*) filter (where p.pickup_done_time is not null) as ped_b,
      coalesce(sum(c.valor) filter (where p.pickup_done_time is not null), 0) as tot_b,
      coalesce(sum(c.valor) filter (where p.pickup_done_time is not null
        and (c.creditado_em at time zone 'America/Sao_Paulo')::date <= (p.pickup_done_time at time zone 'America/Sao_Paulo')::date + 15), 0) as ok_b,
      count(*) as ped_c,
      coalesce(sum(c.valor), 0) as tot_c,
      coalesce(sum(c.valor) filter (
        where (c.creditado_em at time zone 'America/Sao_Paulo')::date <= (p.create_time at time zone 'America/Sao_Paulo')::date + 18), 0) as ok_c
    from cred c
    join shopee_pedidos p on p.order_sn = c.order_sn
    where c.creditado_em >= now() - interval '30 days'
  ),
  gate as (
    select
      ped_a as base_a, case when tot_a > 0 then round((ok_a / tot_a)::numeric, 4) end as acc_a, (ped_a < 50 or (tot_a > 0 and ok_a / tot_a >= 0.80)) as ativo_a,
      ped_b as base_b, case when tot_b > 0 then round((ok_b / tot_b)::numeric, 4) end as acc_b, (ped_b < 50 or (tot_b > 0 and ok_b / tot_b >= 0.80)) as ativo_b,
      ped_c as base_c, case when tot_c > 0 then round((ok_c / tot_c)::numeric, 4) end as acc_c, (ped_c < 50 or (tot_c > 0 and ok_c / tot_c >= 0.80)) as ativo_c
    from acc
  ),
  prev as (
    select b.order_sn, b.valor, b.camada,
           case b.camada
             when 'A' then case when b.order_status = 'COMPLETED' then h.d
                                else greatest((b.delivered_time at time zone 'America/Sao_Paulo')::date + 8, h.d) end
             when 'B' then greatest((b.pickup_done_time at time zone 'America/Sao_Paulo')::date + 15, h.d)
             else          greatest((b.create_time at time zone 'America/Sao_Paulo')::date + 18, h.d)
           end as data,
           case b.camada when 'A' then g.ativo_a when 'B' then g.ativo_b else g.ativo_c end as ativa
    from base b cross join hoje h cross join gate g
    where not b.fora
  ),
  dias as (
    select data, round(sum(valor), 2) as valor from prev where ativa group by data
  )
  select jsonb_build_object(
    'referencia',      (select d from hoje),
    'total',           coalesce((select round(sum(valor),2) from base where not fora), 0),
    'pedidos',         (select count(*) from base where not fora),
    'em_disputa',      coalesce((select round(sum(valor),2) from base where fora), 0),
    'pedidos_disputa', (select count(*) from base where fora),
    'disponivel',      (select current_balance from saldo),
    'cobertura_de',    (select desde::date from cobertura),
    'cobertura_ate',   (select ate::date from cobertura),
    'atualizado_em',   (select max(inserted_at) from shopee_wallet),
    'dias',            coalesce((select jsonb_agg(jsonb_build_object('data', data, 'valor', valor) order by data) from dias), '[]'::jsonb),
    'com_data',        coalesce((select round(sum(valor),2) from prev where ativa), 0),
    'pedidos_com_data',(select count(*) from prev where ativa),
    'sem_data',        coalesce((select round(sum(valor),2) from prev where not ativa), 0),
    'pedidos_sem_data',(select count(*) from prev where not ativa),
    -- por camada (para o selo do card)
    'camadas', jsonb_build_object(
       'entregue',  jsonb_build_object('valor', coalesce((select round(sum(valor),2) from prev where camada='A' and ativa),0), 'pedidos', (select count(*) from prev where camada='A' and ativa), 'ativa', (select ativo_a from gate), 'acuracia_30d', (select acc_a from gate), 'base', (select base_a from gate)),
       'transito',  jsonb_build_object('valor', coalesce((select round(sum(valor),2) from prev where camada='B' and ativa),0), 'pedidos', (select count(*) from prev where camada='B' and ativa), 'ativa', (select ativo_b from gate), 'acuracia_30d', (select acc_b from gate), 'base', (select base_b from gate)),
       'pre_envio', jsonb_build_object('valor', coalesce((select round(sum(valor),2) from prev where camada='C' and ativa),0), 'pedidos', (select count(*) from prev where camada='C' and ativa), 'ativa', (select ativo_c from gate), 'acuracia_30d', (select acc_c from gate), 'base', (select base_c from gate))
    ),
    -- compat com o provider atual (régua A)
    'cronograma_ativo', (select ativo_a from gate),
    'acuracia_30d',    (select acc_a from gate),
    'base_acuracia',   (select base_a from gate)
  );
$$;

comment on function public.shopee_recebiveis() is
  'Recebíveis Shopee: escrow real da API; data DERIVADA em 3 camadas — A entregue: entrega+8d; B em trânsito: coleta+15d (entrega prevista coleta+7d p90 + 8d; backtest 98,5% do valor); C pré-envio: venda+18d (coleta prevista venda+3d p95 + 15d; backtest 99,0%). Detector por camada (30d, piso 80%, base 50) suspende só a camada que driftar. Exclusões: TO_RETURN, compensação, escrow debitado.';
