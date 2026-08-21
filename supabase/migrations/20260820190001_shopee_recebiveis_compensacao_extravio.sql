-- ============================================================================
-- Shopee — compensação de extravio na régua dos recebíveis (Fase 5) · 20/08/2026
-- ============================================================================
-- Achado da conciliação pedido a pedido contra o portal (Minha Renda → Pendente,
-- 20/08/2026, 721 pedidos do portal × 824 do Hub):
--   • 617 batem; 90 "só no portal" eram pedidos de 20-21/08 ainda não ingeridos
--     (lag intradiário do cron — se resolvem sozinhos); 28+4 "só no Hub" tinham
--     concluído/liberado horas antes do nosso sync (timing); 14 são nossa
--     exclusão em_disputa (mais correta que o portal).
--   • BUG REAL (este fix): pedido pago via "Reembolso por objeto perdido"
--     entra na carteira como MONEY_IN com transaction_type VAZIO — a régua só
--     conhecia ESCROW_VERIFIED_ADD e RETURN_COMPENSATION_SERVICE_ADD, então o
--     pedido ficava "a receber" PARA SEMPRE (7 pedidos, R$ 1.015,27, alguns
--     desde junho — e como estavam COMPLETED, o cronograma os fixava em "hoje"
--     eternamente). Medido: as ÚNICAS linhas de tipo vazio da carteira são
--     essas compensações (24 pedidos, R$ 3.663,65, todas MONEY_IN/COMPLETED/
--     "Reembolso por objeto perdido").
-- Fix: tipo vazio + MONEY_IN = compensação (pago por outro caminho) → sai do
-- "a receber" e vai para em_disputa, como o RETURN_COMPENSATION já fazia.

create or replace function shopee_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
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
           p.delivered_time,
           (p.order_status = 'TO_RETURN'
            or coalesce(m.teve_compensacao, false)
            or coalesce(m.teve_debito, false)) as fora,
           (p.order_status = 'COMPLETED' or p.delivered_time is not null) as tem_data
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
  acc as (
    select count(*) as pedidos,
           coalesce(sum(c.valor), 0) as valor_total,
           coalesce(sum(c.valor) filter (
             where (c.creditado_em at time zone 'America/Sao_Paulo')::date
                <= (p.delivered_time at time zone 'America/Sao_Paulo')::date + 9), 0) as valor_no_prazo
    from cred c
    join shopee_pedidos p on p.order_sn = c.order_sn
    where c.creditado_em >= now() - interval '30 days'
      and p.delivered_time is not null
      and p.delivered_time < c.creditado_em
  ),
  gate as (
    select pedidos as base_pedidos,
           case when valor_total > 0 then round((valor_no_prazo / valor_total)::numeric, 4) end as acuracia,
           (pedidos < 50 or (valor_total > 0 and valor_no_prazo / valor_total >= 0.80)) as ativo
    from acc
  ),
  prev as (
    select case
             when b.order_status = 'COMPLETED' then h.d
             else greatest((b.delivered_time at time zone 'America/Sao_Paulo')::date + 8, h.d)
           end as data,
           b.valor
    from base b cross join hoje h
    where not b.fora and b.tem_data
  ),
  dias as (
    select data, round(sum(valor), 2) as valor from prev group by data
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
    'dias',            case when (select ativo from gate)
                            then coalesce((select jsonb_agg(jsonb_build_object('data', data, 'valor', valor) order by data) from dias), '[]'::jsonb)
                            else '[]'::jsonb end,
    'com_data',        case when (select ativo from gate)
                            then coalesce((select round(sum(valor),2) from base where not fora and tem_data), 0)
                            else 0 end,
    'pedidos_com_data', case when (select ativo from gate)
                            then (select count(*) from base where not fora and tem_data)
                            else 0 end,
    'sem_data',        case when (select ativo from gate)
                            then coalesce((select round(sum(valor),2) from base where not fora and not tem_data), 0)
                            else coalesce((select round(sum(valor),2) from base where not fora), 0) end,
    'pedidos_sem_data', case when (select ativo from gate)
                            then (select count(*) from base where not fora and not tem_data)
                            else (select count(*) from base where not fora) end,
    'cronograma_ativo', (select ativo from gate),
    'acuracia_30d',    (select acuracia from gate),
    'base_acuracia',   (select base_pedidos from gate)
  );
$function$;

comment on function shopee_recebiveis() is
  'Recebíveis Shopee: escrow real ainda não creditado + cronograma com data DERIVADA (Camada A). Exclusões: TO_RETURN, débito sem crédito, RETURN_COMPENSATION e compensação de extravio (MONEY_IN de tipo vazio — fix 20/08). Detector de drift: acurácia 30d < 80% suspende o cronograma. Valores 100% da API.';
