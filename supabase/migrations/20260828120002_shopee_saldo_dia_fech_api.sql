-- ═══════════════════════════════════════════════════════════════════════════
-- shopee_saldo_dia v2 — fechamento pela API, "taxa oculta de R$ 0,49" medida
-- (28/08/2026, mesma sessão da 20260828120001)
--
-- A v1 ancorava a série no current_balance da última transação e integrava por
-- Σamount. A validação pegou drift de até R$ 7,36: em parte dos créditos
-- ESCROW_VERIFIED_ADD o saldo da carteira sobe R$ 0,49 A MENOS que o `amount`
-- (28 ocorrências desde 25/07, sempre −0,49, mais ±0,01 de arredondamento em
-- BR_DIFAL/ADJUSTMENT) — débito oculto da Shopee no ato do crédito, que a
-- integração por amounts não enxerga e acumula para trás.
--
-- v2: o FECHAMENTO do dia é o current_balance da última transação DO DIA
-- (a verdade da carteira, carregada nos dias sem transação), e a diferença
-- (créditos − débitos − saques) − Δsaldo vira a coluna `ajuste`, SOMADA aos
-- débitos do dia — é taxa real, não erro. Identidade exata por construção:
-- fech(D) = fech(D−1) + creditos − debitos − payouts, com debitos já ajustado.
-- `ajuste` fica exposto para monitoração: hoje ≤ ~R$ 1,50/dia; valor grande =
-- transação faltando na ingestão (investigar, nunca aceitar em silêncio).
-- ═══════════════════════════════════════════════════════════════════════════

drop view public.shopee_saldo_dia; -- a v1 tinha colunas fechamento_api/residuo (replace não pode removê-las)

create view public.shopee_saldo_dia as
with mov as (
  select (create_time at time zone 'America/Sao_Paulo')::date as dia,
         coalesce(sum(amount) filter (where money_flow = 'MONEY_IN'), 0) as creditos,
         coalesce(-sum(amount) filter (where money_flow = 'MONEY_OUT'
                                         and transaction_type <> 'WITHDRAWAL_CREATED'), 0) as debitos_api,
         coalesce(-sum(amount) filter (where transaction_type = 'WITHDRAWAL_CREATED'), 0) as payouts
  from public.shopee_wallet
  group by 1
),
api as (
  -- saldo da carteira no fim de cada dia com transação (a verdade da Shopee)
  select distinct on ((create_time at time zone 'America/Sao_Paulo')::date)
         (create_time at time zone 'America/Sao_Paulo')::date as dia,
         current_balance
  from public.shopee_wallet
  order by (create_time at time zone 'America/Sao_Paulo')::date, create_time desc, transaction_id desc
),
serie as (
  select m.dia, m.creditos, m.debitos_api, m.payouts,
         a.current_balance as fechamento,
         lag(a.current_balance) over (order by m.dia) as fech_ant
  from mov m
  join api a using (dia)
)
select dia,
       round(creditos, 2) as creditos,
       -- débitos = amounts de saída + ajuste (a parte que a Shopee debita sem linha própria)
       round(debitos_api + coalesce((creditos - debitos_api - payouts) - (fechamento - fech_ant), 0), 2) as debitos,
       round(payouts, 2) as payouts,
       fechamento,
       round(coalesce((creditos - debitos_api - payouts) - (fechamento - fech_ant), 0), 2) as ajuste
from serie;

comment on view public.shopee_saldo_dia is
'Série diária da carteira Shopee p/ o caixa consolidado (v2, 28/08/2026). fechamento = current_balance da última transação do dia (verdade da carteira). creditos = MONEY_IN; debitos = MONEY_OUT exceto saque + AJUSTE (taxa oculta: parte dos ESCROW_VERIFIED_ADD credita R$0,49 a menos que o amount — débito real sem linha própria); payouts = WITHDRAWAL_CREATED (perna interna do saque). Identidade exata: fech(D) = fech(D−1) + creditos − debitos − payouts. Coluna ajuste é monitoração: ≤ ~R$1,50/dia esperado; valor grande = transação faltando na ingestão.';
