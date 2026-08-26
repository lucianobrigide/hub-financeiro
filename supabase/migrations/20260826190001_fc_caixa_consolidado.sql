-- F.C. Projetado: CAIXA CONSOLIDADO = bancos + saldo disponível do Mercado Pago
-- (continuação de 20260826180001; pedido do Luciano 26/08/2026: o dinheiro já
--  liberado no MP e ainda não transferido precisa estar no saldo).
--
-- fc_historico v5:
--   fechamento(D) = Σ saldo_fim dos bancos (extrato Omie) + mp_saldo_dia.fechamento(D)
--   entradas(D)   = banco (transf. entre contas de caixa E vindas do "Mercado
--                   Pago" agora são INTERNAS) + créditos reais do disponível MP
--   saídas(D)     = banco (idem) + débitos reais do disponível MP
--   hoje: abertura = fechamento consolidado de ontem; ent/sai reais = extrato
--   bancário parcial de hoje (fluxo intradiário do MP não é medido — as
--   liberações de hoje seguem como entrada PROJETADA do cronograma, e a
--   transferência MP→banco é interna dos dois lados).
--   Identidade: fech(D) = fech(D−1) + ent − sai (payout do MP e o crédito
--   correspondente no banco caem no mesmo dia — Pix — e se anulam).
-- Dia do extrato bancário sem série MP (não deveria ocorrer após o backfill
-- 01/08→hoje): usa o último fechamento MP conhecido com fluxo 0 (carry).

create or replace function public.fc_historico(p_dias int default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date as d
),
n_caixa as (select count(*) as n from public.omie_saldos_cc where conta_caixa),
-- nomes que contam como "dentro do caixa": contas de caixa + o bolso MP
nomes_internos as (
  select descricao from public.omie_saldos_cc where conta_caixa
  union select 'Mercado Pago'
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
-- série MP com carry (dia sem relatório usa o último fechamento conhecido, fluxo 0)
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
         f.ent_real as banco_ent, f.sai_real as banco_sai
  from ext e
  full join snap s using (data)
  left join ext_fluxo f on f.data = coalesce(e.data, s.data)
  left join mp on mp.data = coalesce(e.data, s.data)
),
dias2 as (
  select d.*,
         -- consolidado só quando banco (completo) existe; MP entra com carry
         case when d.fech_banco is not null
              then round(d.fech_banco + coalesce(d.fech_mp, 0), 2) end as fech_cons,
         case when d.fech_banco is not null
              then round(coalesce(d.banco_ent, 0) + coalesce(d.mp_cred, 0), 2) end as ent_cons,
         case when d.fech_banco is not null
              then round(coalesce(d.banco_sai, 0) + coalesce(d.mp_deb, 0), 2) end as sai_cons
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
         coalesce((select f.ent_real from ext_fluxo f, hoje h where f.data = h.d), 0) as ent_real,
         coalesce((select f.sai_real from ext_fluxo f, hoje h where f.data = h.d), 0) as sai_real,
         coalesce((select e.contas from ext e, hoje h where e.data = h.d), 0) as contas,
         (select e.coletado_em from ext e, hoje h where e.data = h.d) as coletado_em,
         (select mp.fechamento from mp, hoje h where mp.data = h.d - 1) as mp_disponivel,
         (select max(m2.data) from public.mp_saldo_dia m2 where m2.fechamento is not null) as mp_data
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
      'mp_data', hj.mp_data
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

comment on function public.fc_historico(int) is
'Histórico do F.C. em caixa CONSOLIDADO (bancos + saldo disponível do Mercado Pago): por dia, abertura, ent_real/sai_real (extrato bancário com transferências internas excluídas — incl. MP→banco — + fluxos reais do disponível MP) e fechamento = bancos_fim + mp_fim; identidade exata. `hoje`: abertura = fechamento consolidado de ontem + mp_disponivel para o card; ent/sai reais = extrato bancário parcial. Fallback foto para dia sem extrato. Default p_dias=NULL = tudo.';
