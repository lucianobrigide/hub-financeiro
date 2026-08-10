-- SHEIN settlement: ingestão dos check orders (liquidação REAL, o dinheiro que
-- a SHEIN paga) + conciliação contra a régua v2 do card.
--
-- Descoberta 10/08/2026 (endpoints via SDK público easycb-go; app tem permissão):
--   POST /open-api/finance/get-check-order-list  {startAddTime, endAddTime, page, pageSize}
--     - janela < 7 dias (7 exatos é rejeitado), pageSize 1..30, horários UTC+8
--     - 1 check order (Dxxxx) por pedido; reportOrderNo (Bxxxx) = ciclo de repasse
--     - checkStatus: 1 = aguardando (estimatePayTime), 3 = PAGO (completedPayTime)
--   GET  /open-api/finance/get-check-order-detail?checkOrderNo=Dxxxx
--     - decomposição por item: comissão, performanceCost, promo, impostos/retenções
--   POST /open-api/finance/report-list → 403 (sem permissão no portal; pedir se precisar)
--
-- VALIDADO no primeiro pagamento real (10/08/2026, repasse B2608055555577856):
--   3 pedidos pagos = R$ 109,46 + 173,52 + 173,52 — IGUAL à régua v2 e ao
--   estimatedGrossIncome, centavo a centavo. Detalhe do pago: whtTotalAmount,
--   commissionSaleTax, sellerRealTax, GNRE, returnExpense TODOS zero no BR —
--   sem custo oculto além de comissão + taxa (− subsídio).

create table public.shein_settlement (
  check_order_no          text primary key,       -- Dxxxx
  order_no                text not null,          -- bzOrderNo (GSHxxxx)
  check_status            int,                    -- 1 aguardando · 3 pago
  income_expenditure_type int,                    -- 1 receita · 2 despesa (estorno)
  second_order_type       int,
  report_order_no         text,                   -- Bxxxx (ciclo de repasse)
  business_completed_time timestamptz,
  estimate_pay_time       timestamptz,
  completed_pay_time      timestamptz,
  currency                text,
  valor_estimado          numeric(14,2),          -- estimateIncomeMoneyTotal
  raw                     jsonb,
  inserted_at             timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
comment on table public.shein_settlement is
  'Check orders da liquidacao SHEIN (get-check-order-list). 1 linha por pedido x tipo; checkStatus 3 = pago. Horarios da API em UTC+8. valor_estimado validado = pago real nos 3 primeiros pagamentos (10/08/2026).';
create index shein_settlement_order_no_idx on public.shein_settlement (order_no);
create index shein_settlement_status_idx on public.shein_settlement (check_status);
alter table public.shein_settlement enable row level security;

-- Ingestão por janela de addTime: varre [p_de, p_ate) em janelas de 6 dias
-- (cap da API: < 7), pagina de 30 em 30, upsert. Janela em subtransação
-- (padrão fases resilientes). Re-varrer janelas antigas captura a transição
-- checkStatus 1 → 3 (pagamento ocorre ~9 dias após o addTime).
create or replace function public.shein_fill_settlement(p_de timestamptz, p_ate timestamptz)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_ini timestamptz := p_de;
  v_fim timestamptz;
  v_fmt_ini text; v_fmt_fim text;
  v_resp jsonb; v_body jsonb; v_list jsonb;
  v_page int; v_count int;
  v_rows int := 0; v_jan int := 0; v_err int := 0;
  v_t0 timestamptz := clock_timestamp();
  e jsonb;
begin
  while v_ini < p_ate loop
    v_fim := least(v_ini + interval '6 days', p_ate);
    v_jan := v_jan + 1;
    begin
      v_fmt_ini := to_char(v_ini at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS');
      v_fmt_fim := to_char(v_fim at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS');

      v_page := 1;
      loop
        v_resp := public.shein_api_call('/open-api/finance/get-check-order-list', jsonb_build_object(
          'startAddTime', v_fmt_ini, 'endAddTime', v_fmt_fim,
          'page', v_page, 'pageSize', 30));
        v_body := v_resp->'body';
        if (v_resp->>'http_status')::int is distinct from 200 or (v_body->>'code') <> '0' then
          raise exception 'get-check-order-list falhou (janela % → %): HTTP % | %',
            v_fmt_ini, v_fmt_fim, v_resp->>'http_status', left(coalesce(v_body::text, 'sem corpo'), 300);
        end if;
        v_list := v_body->'info'->'list';
        exit when v_list is null or jsonb_array_length(v_list) = 0;

        for e in select * from jsonb_array_elements(v_list)
        loop
          insert into public.shein_settlement as s (
            check_order_no, order_no, check_status, income_expenditure_type,
            second_order_type, report_order_no,
            business_completed_time, estimate_pay_time, completed_pay_time,
            currency, valor_estimado, raw, updated_at
          ) values (
            e->>'checkOrderNo',
            e->>'bzOrderNo',
            (e->>'checkStatus')::int,
            (e->>'incomeExpenditureType')::int,
            (e->>'secondOrderType')::int,
            nullif(e->>'reportOrderNo', ''),
            nullif(e->>'businessCompletedTime', '')::timestamp at time zone 'Asia/Shanghai',
            nullif(e->>'estimatePayTime', '')::timestamp at time zone 'Asia/Shanghai',
            nullif(e->>'completedPayTime', '')::timestamp at time zone 'Asia/Shanghai',
            e->>'currencyCode',
            (e->>'estimateIncomeMoneyTotal')::numeric,
            e, now()
          )
          on conflict (check_order_no) do update set
            check_status            = excluded.check_status,
            report_order_no         = excluded.report_order_no,
            estimate_pay_time       = excluded.estimate_pay_time,
            completed_pay_time      = excluded.completed_pay_time,
            valor_estimado          = excluded.valor_estimado,
            raw                     = excluded.raw,
            updated_at              = now();
          v_rows := v_rows + 1;
        end loop;

        v_count := coalesce((v_body->'info'->>'count')::int, 0);
        exit when v_page * 30 >= v_count or v_page >= 40;
        v_page := v_page + 1;
      end loop;
    exception when others then
      v_err := v_err + 1;
      insert into public.ml_cron_log (job, dia_alvo, sucesso, mensagem)
      values ('shein_settlement', (v_ini at time zone 'America/Sao_Paulo')::date, false,
              'janela ' || v_fmt_ini || '→' || v_fmt_fim || ': ' || SQLERRM);
    end;
    v_ini := v_fim;
  end loop;

  insert into public.ml_cron_log (job, dia_alvo, sucesso, pedidos, duracao_ms, mensagem)
  values ('shein_settlement', (p_ate at time zone 'America/Sao_Paulo')::date, v_err = 0, v_rows,
          (extract(epoch from clock_timestamp() - v_t0) * 1000)::int,
          format('janelas=%s registros=%s erros=%s (%s → %s)', v_jan, v_rows, v_err,
                 to_char(p_de at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                 to_char(p_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')));

  return jsonb_build_object('janelas', v_jan, 'registros', v_rows, 'erros', v_err);
end $$;

-- Cron diário: pedidos (3d) + settlement (14d — recaptura a virada 1→3, que
-- acontece ~9 dias após o addTime). Fases independentes: uma falhar não
-- derruba a outra (subtransação dentro de cada fill; aqui só encadeia).
create or replace function public.shein_cron_diario()
returns jsonb language sql security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'pedidos',    public.shein_fill_pedidos(now() - interval '3 days', now()),
    'settlement', public.shein_fill_settlement(now() - interval '14 days', now())
  );
$$;

-- Semanal: re-sync amplo dos dois (30d pedidos / 35d settlement).
create or replace function public.shein_cron_semanal()
returns jsonb language sql security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'pedidos',    public.shein_fill_pedidos(now() - interval '30 days', now()),
    'settlement', public.shein_fill_settlement(now() - interval '35 days', now())
  );
$$;

-- Re-agenda o semanal para a função nova (o diário já chama shein_cron_diario).
select cron.unschedule('shein-semanal');
select cron.schedule('shein-semanal', '35 8 * * 0',
  $cmd$SET statement_timeout='900s'; SELECT public.shein_cron_semanal()$cmd$);

-- Conciliação: settlement (dinheiro) × régua v2 do card (estimado), por mês de
-- competência do PEDIDO (payment_time BRT). Divergência = pago ≠ estimado.
create or replace function public.shein_conciliacao(p_month text)
returns jsonb language sql stable security definer
set search_path to 'public'
as $$
  with regua as (
    select i.order_no,
           round(sum(i.preco_com_desconto - i.comissao - i.taxa_servico
                 + ((coalesce(i.preco,0) - coalesce(i.cupom,0) - coalesce(i.promo,0)) - i.preco_com_desconto)), 2) receita
    from public.shein_itens i
    join public.shein_pedidos p on p.order_no = i.order_no
    where to_char(coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
      and p.order_status not in (6,8,9)
    group by 1
  ),
  s as (
    select order_no,
           sum(valor_estimado) filter (where check_status = 3 and income_expenditure_type = 1) pago,
           sum(valor_estimado) filter (where check_status <> 3 and income_expenditure_type = 1) aguardando,
           bool_or(check_status = 3) tem_pago
    from public.shein_settlement
    group by 1
  )
  select jsonb_build_object(
    'pedidos_mes',        (select count(*) from regua),
    'receita_estimada',   (select coalesce(sum(receita), 0) from regua),
    'pedidos_pagos',      (select count(*) from regua r join s on s.order_no = r.order_no and s.tem_pago),
    'valor_pago',         (select coalesce(sum(s.pago), 0) from regua r join s on s.order_no = r.order_no),
    'pedidos_aguardando', (select count(*) from regua r join s on s.order_no = r.order_no and not s.tem_pago),
    'valor_aguardando',   (select coalesce(sum(s.aguardando), 0) from regua r join s on s.order_no = r.order_no),
    'sem_check_order',    (select count(*) from regua r where not exists (select 1 from s where s.order_no = r.order_no)),
    'divergentes',        (select count(*) from regua r join s on s.order_no = r.order_no and s.tem_pago
                            where abs(coalesce(s.pago, 0) - r.receita) > 0.01),
    'divergencia_total',  (select coalesce(sum(coalesce(s.pago, 0) - r.receita), 0)
                             from regua r join s on s.order_no = r.order_no and s.tem_pago)
  );
$$;

-- Permissões: só service_role
revoke all on function public.shein_fill_settlement(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.shein_cron_semanal()                            from public, anon, authenticated;
revoke all on function public.shein_conciliacao(text)                         from public, anon, authenticated;
grant execute on function public.shein_fill_settlement(timestamptz, timestamptz) to service_role;
grant execute on function public.shein_cron_semanal()                            to service_role;
grant execute on function public.shein_conciliacao(text)                         to service_role;
