-- ═══════════════════════════════════════════════════════════════════════════
-- CAIXA CONSOLIDADO = bancos + MP + SHOPEE (carteira) — 28/08/2026
-- Pedido do Luciano: "os ~50k disponíveis para saque na Shopee precisam estar
-- no saldo" (mesmo tratamento dado ao Mercado Pago em 26/08, 20260826180001).
--
-- Fonte: shopee_wallet (transaction list, já coletada 2×/dia por shopee-wallet/
-- shopee-wallet-tarde). Nada estimado: todo valor vem da própria carteira.
--
-- Réguas medidas antes de ligar (28/08/2026):
--  · Identidade por transação: amount = Δcurrent_balance em ~99,5% das linhas
--    (exceções são EMPATES de ordenação no mesmo segundo — a SOMA do dia não
--    muda). Por isso a série diária é ANCORADA no current_balance da última
--    transação e integrada por Σamount — exata por construção; o
--    current_balance de fim de dia vira coluna de VALIDAÇÃO (resíduo observado
--    ≤ R$ 1,47, só empates).
--  · Saque = WITHDRAWAL_CREATED (perna interna, estilo payout do MP);
--    WITHDRAWAL_COMPLETED tem amount 0 (marcador).
--  · A perna bancária ("Transf. Shopee >> Itaú", categoria 0.01.%) NEM SEMPRE
--    cai no mesmo dia (saque de 6ª/sáb. cai na 2ª: 01/08→03/08, 07/08→10/08).
--    Por isso existe o balde EM TRÂNSITO: transito(D) = Σ saques ≤ D − Σ
--    créditos bancários "Transf. Shopee >>" ≤ D. Baseline: trânsito = 0 em
--    31/07 (validado: todo crédito bancário ≥ 01/08 casa com um saque ≥ 01/08).
--  · Consolidado: fech(D) = bancos + MP + carteira Shopee + trânsito;
--    ent/sai excluem as DUAS pernas do saque (interno) — identidade exata.
--  · Liberação de escrow (ESCROW_VERIFIED_ADD) = ENTRADA real no consolidado.
--    Bônus de correção: o cronograma de recebíveis da Shopee projeta a DATA DE
--    LIBERAÇÃO (entrega+8d etc.) — antes a entrada real só aparecia no saque;
--    agora "liberou = entrou", igual ao Mercado Pago (money_release_date).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Série diária da carteira Shopee ─────────────────────────────────────────
create or replace view public.shopee_saldo_dia as
with mov as (
  select (create_time at time zone 'America/Sao_Paulo')::date as dia,
         sum(amount) as delta,
         coalesce(sum(amount) filter (where money_flow = 'MONEY_IN'), 0) as creditos,
         coalesce(-sum(amount) filter (where money_flow = 'MONEY_OUT'
                                         and transaction_type <> 'WITHDRAWAL_CREATED'), 0) as debitos,
         coalesce(-sum(amount) filter (where transaction_type = 'WITHDRAWAL_CREATED'), 0) as payouts
  from public.shopee_wallet
  group by 1
),
anc as (
  -- âncora: saldo após a última transação ingerida
  select current_balance as bal
  from public.shopee_wallet
  order by create_time desc, transaction_id desc
  limit 1
),
api as (
  -- current_balance no fim de cada dia (validação; empates de ordenação podem
  -- desviar centavos — a série oficial é a ancorada)
  select distinct on ((create_time at time zone 'America/Sao_Paulo')::date)
         (create_time at time zone 'America/Sao_Paulo')::date as dia,
         current_balance
  from public.shopee_wallet
  order by (create_time at time zone 'America/Sao_Paulo')::date, create_time desc, transaction_id desc
)
select m.dia,
       round(m.creditos, 2) as creditos,
       round(m.debitos, 2)  as debitos,
       round(m.payouts, 2)  as payouts,
       round((select bal from anc)
             - coalesce(sum(m.delta) over (order by m.dia desc
                                           rows between unbounded preceding and 1 preceding), 0),
             2) as fechamento,
       a.current_balance as fechamento_api,
       round((select bal from anc)
             - coalesce(sum(m.delta) over (order by m.dia desc
                                           rows between unbounded preceding and 1 preceding), 0)
             - a.current_balance, 2) as residuo
from mov m
left join api a using (dia);

comment on view public.shopee_saldo_dia is
'Série diária da carteira Shopee para o caixa consolidado (28/08/2026). fechamento = âncora (current_balance da última transação) − Σ amounts dos dias seguintes: exato por construção. creditos = MONEY_IN; debitos = MONEY_OUT exceto saque; payouts = WITHDRAWAL_CREATED (perna interna do saque p/ banco). fechamento_api/residuo = validação contra o current_balance de fim de dia (resíduo esperado ≤ ~R$1,50, empates de ordenação no mesmo segundo).';

-- ── fc_historico v6: consolida bancos + MP + Shopee (carteira + trânsito) ───
create or replace function public.fc_historico(p_dias integer default null)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date as d
),
n_caixa as (select count(*) as n from public.omie_saldos_cc where conta_caixa),
nomes_internos as (
  select descricao from public.omie_saldos_cc where conta_caixa
  union select 'Mercado Pago'
  union select 'Shopee'
),
mov as (
  select e.data, (m->>'nValorDocumento')::numeric as v,
         coalesce(m->>'cCodCategoria','') like '0.01.%' as transf,
         coalesce(m->>'cDesCliente','') as descr
  from public.omie_extrato_dia e
  join public.omie_saldos_cc c on c.n_cod_cc = e.n_cod_cc and c.conta_caixa
  cross join lateral jsonb_array_elements(e.movimentos) m
  where (m->>'nValorDocumento')::numeric <> 0
    and coalesce(m->>'cSituacao', '') <> 'Previsto'
),
movx as (
  select * from mov m
  where not (m.transf
    and exists (select 1 from nomes_internos cn
                where trim(regexp_replace(m.descr, '^Transf\.\s*(.*?)\s*&gt;&gt;.*$', '\1')) = cn.descricao)
    and exists (select 1 from nomes_internos cn
                where trim(regexp_replace(m.descr, '^.*&gt;&gt;\s*(.*)$', '\1')) = cn.descricao))
),
ext_fluxo as (
  select data,
         coalesce(sum(v) filter (where v > 0), 0)::numeric(14,2) as ent_real,
         coalesce(-sum(v) filter (where v < 0), 0)::numeric(14,2) as sai_real
  from movx group by data
),
ext as (
  select e.data, sum(e.saldo_fim)::numeric(14,2) as fechamento_ext, count(*) as contas,
         max(e.coletado_em) as coletado_em
  from public.omie_extrato_dia e
  join public.omie_saldos_cc c on c.n_cod_cc = e.n_cod_cc and c.conta_caixa
  group by e.data
),
mp as (
  select g.d as data,
         (select m2.fechamento from public.mp_saldo_dia m2
          where m2.data <= g.d and m2.fechamento is not null
          order by m2.data desc limit 1) as fechamento,
         coalesce(m.creditos, 0)::numeric(14,2) as creditos,
         coalesce(m.debitos, 0)::numeric(14,2) as debitos
  from (select generate_series((select min(data) from public.mp_saldo_dia),
                               (select d from hoje), interval '1 day')::date as d) g
  left join public.mp_saldo_dia m on m.data = g.d
),
-- Carteira Shopee: fechamento carregado (dia sem transação herda o anterior)
sh as (
  select g.d as data,
         (select s2.fechamento from public.shopee_saldo_dia s2
          where s2.dia <= g.d order by s2.dia desc limit 1) as fechamento,
         coalesce(s.creditos, 0)::numeric(14,2) as creditos,
         coalesce(s.debitos, 0)::numeric(14,2) as debitos
  from (select generate_series(date '2026-08-01', (select d from hoje), interval '1 day')::date as d) g
  left join public.shopee_saldo_dia s on s.dia = g.d
),
-- Perna bancária do saque Shopee (crédito "Transf. Shopee >> <conta de caixa>")
sh_land as (
  select m.data, sum(m.v) as v
  from mov m
  where m.transf and m.v > 0
    and trim(regexp_replace(m.descr, '^Transf\.\s*(.*?)\s*&gt;&gt;.*$', '\1')) = 'Shopee'
  group by m.data
),
-- Em trânsito: saque saiu da carteira mas ainda não caiu no banco (fim de semana).
-- Baseline trânsito = 0 em 31/07 (validado 28/08/2026).
sh_trans as (
  select g.data,
         round(coalesce((select sum(s.payouts) from public.shopee_saldo_dia s
                         where s.dia between date '2026-08-01' and g.data), 0)
             - coalesce((select sum(l.v) from sh_land l
                         where l.data between date '2026-08-01' and g.data), 0), 2) as transito
  from sh g
),
snap as (
  select data, saldo_caixa,
         (curva->0->>'entradas')::numeric as ent_prev,
         (curva->0->>'saidas')::numeric   as sai_prev,
         lead(data)        over (order by data) as fechamento_data,
         lead(saldo_caixa) over (order by data) as fechamento
  from public.fc_snapshot
),
dias as (
  select coalesce(e.data, s.data) as data,
         s.saldo_caixa as abertura_foto,
         s.ent_prev, s.sai_prev,
         s.fechamento as fech_foto, s.fechamento_data as fech_foto_data,
         case when e.contas = (select n from n_caixa) then e.fechamento_ext end as fech_banco,
         mp.fechamento as fech_mp, mp.creditos as mp_cred, mp.debitos as mp_deb,
         sh.fechamento as fech_sh, sh.creditos as sh_cred, sh.debitos as sh_deb,
         st.transito as sh_transito,
         f.ent_real as banco_ent, f.sai_real as banco_sai
  from ext e
  full join snap s using (data)
  left join ext_fluxo f on f.data = coalesce(e.data, s.data)
  left join mp on mp.data = coalesce(e.data, s.data)
  left join sh on sh.data = coalesce(e.data, s.data)
  left join sh_trans st on st.data = coalesce(e.data, s.data)
),
dias2 as (
  select d.*,
         case when d.fech_banco is not null
              then round(d.fech_banco + coalesce(d.fech_mp, 0)
                         + coalesce(d.fech_sh, 0) + coalesce(d.sh_transito, 0), 2) end as fech_cons,
         case when d.fech_banco is not null
              then round(coalesce(d.banco_ent, 0) + coalesce(d.mp_cred, 0)
                         + coalesce(d.sh_cred, 0), 2) end as ent_cons,
         case when d.fech_banco is not null
              then round(coalesce(d.banco_sai, 0) + coalesce(d.mp_deb, 0)
                         + coalesce(d.sh_deb, 0), 2) end as sai_cons
  from dias d
),
ult_fechado as (
  select d2.fech_cons
  from dias2 d2, hoje h
  where d2.data < h.d and d2.fech_cons is not null
  order by d2.data desc limit 1
),
hj as (
  select (select d from hoje) as data,
         (select fech_cons from ult_fechado) as abertura,
         -- movimento REAL de hoje: extrato parcial dos bancos + carteira Shopee
         -- parcial (a carteira é coletada 2×/dia; liberação de hoje já ingerida
         -- conta como entrada real e o pedido sai do projetado dos recebíveis —
         -- mesmo mecanismo do AP × extrato)
         coalesce((select f.ent_real from ext_fluxo f, hoje h where f.data = h.d), 0)
           + coalesce((select s.creditos from sh s, hoje h where s.data = h.d), 0) as ent_real,
         coalesce((select f.sai_real from ext_fluxo f, hoje h where f.data = h.d), 0)
           + coalesce((select s.debitos from sh s, hoje h where s.data = h.d), 0) as sai_real,
         coalesce((select e.contas from ext e, hoje h where e.data = h.d), 0) as contas,
         (select e.coletado_em from ext e, hoje h where e.data = h.d) as coletado_em,
         (select mp.fechamento from mp, hoje h where mp.data = h.d - 1) as mp_disponivel,
         (select max(m2.data) from public.mp_saldo_dia m2 where m2.fechamento is not null) as mp_data,
         -- carteira Shopee AGORA (inclui as transações de hoje já ingeridas)
         (select s2.fechamento from public.shopee_saldo_dia s2 order by s2.dia desc limit 1) as sh_disponivel,
         (select max(s2.dia) from public.shopee_saldo_dia s2) as sh_data,
         (select st.transito from sh_trans st, hoje h where st.data = h.d) as sh_transito,
         (select max(w.inserted_at) from public.shopee_wallet w) as sh_coletado_em
)
select jsonb_build_object(
  'referencia', (select d from hoje),
  'hoje', (select jsonb_build_object(
      'data', hj.data,
      'abertura', hj.abertura,
      'ent_real', hj.ent_real,
      'sai_real', hj.sai_real,
      'completo', hj.contas = (select n from n_caixa) and hj.abertura is not null,
      'coletado_em', hj.coletado_em,
      'mp_disponivel', hj.mp_disponivel,
      'mp_data', hj.mp_data,
      'sh_disponivel', hj.sh_disponivel,
      'sh_data', hj.sh_data,
      'sh_transito', hj.sh_transito,
      'sh_coletado_em', hj.sh_coletado_em
    ) from hj),
  'dias', coalesce((
    select jsonb_agg(jsonb_build_object(
      'data',            x.data,
      'abertura',        case when x.fech_cons is not null
                              then round(x.fech_cons - x.ent_cons + x.sai_cons, 2)
                              else x.abertura_foto end,
      'fechamento',      coalesce(x.fech_cons, x.fech_foto),
      'fonte',           case when x.fech_cons is not null then 'extrato'
                              when x.fech_foto is not null then 'foto' end,
      'fechamento_data', case when x.fech_cons is not null then x.data else x.fech_foto_data end,
      'ent_real',        x.ent_cons,
      'sai_real',        x.sai_cons,
      'movimento',       case when x.fech_cons is not null
                              then round(x.ent_cons - x.sai_cons, 2)
                              else round(x.fech_foto - x.abertura_foto, 2) end,
      'ent_prev',        round(x.ent_prev, 2),
      'sai_prev',        round(x.sai_prev, 2)
    ) order by x.data)
    from dias2 x, hoje h
    where x.data < h.d and (p_dias is null or x.data >= h.d - p_dias)
  ), '[]'::jsonb)
);
$function$;

comment on function public.fc_historico(integer) is
'v6 (28/08/2026): caixa consolidado = bancos + MP + CARTEIRA SHOPEE + saque em trânsito. fechamento(D) = Σ saldo_fim contas de caixa + fech MP + fech carteira Shopee (shopee_saldo_dia, ancorada) + trânsito (saque criado e ainda não caído no banco — saque de 6ª/sáb. cai na 2ª). ent/sai excluem as pernas internas: banco↔banco, MP→banco e Shopee→banco (nomes_internos). ent_real de hoje inclui a carteira Shopee parcial do dia (coletada 2×/dia). Identidade exata: fech(D) = fech(D−1) + ent − sai. Abertura de hoje = fechamento consolidado de ontem.';
