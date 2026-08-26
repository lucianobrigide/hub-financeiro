-- F.C. Projetado: ABERTURA do dia no histórico (pedido do Luciano 26/08/2026:
-- "deve ter o saldo inicial do dia, as entradas do dia, as saídas do dia e o
-- saldo final do dia").
--
-- Nos dias fechados pelo EXTRATO, `abertura` passa a ser o SALDO INICIAL DO
-- DIA (= fechamento − entradas + saídas, exato pela identidade do extrato —
-- equivale ao fechamento do dia anterior). No fallback por foto, `abertura`
-- segue sendo o saldo da foto das 08:45 do próprio dia (aproximação da
-- abertura). Nenhuma outra mudança de contrato.

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
caixa_nomes as (select descricao from public.omie_saldos_cc where conta_caixa),
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
    and exists (select 1 from caixa_nomes cn
                where trim(regexp_replace(m.descr, '^Transf\.\s*(.*?)\s*&gt;&gt;.*$', '\1')) = cn.descricao)
    and exists (select 1 from caixa_nomes cn
                where trim(regexp_replace(m.descr, '^.*&gt;&gt;\s*(.*)$', '\1')) = cn.descricao))
),
ext_fluxo as (
  select data,
         coalesce(sum(v) filter (where v > 0), 0)::numeric(14,2) as ent_real,
         coalesce(-sum(v) filter (where v < 0), 0)::numeric(14,2) as sai_real
  from movx group by data
),
ext as (
  select e.data, sum(e.saldo_fim)::numeric(14,2) as fechamento_ext, count(*) as contas
  from public.omie_extrato_dia e
  join public.omie_saldos_cc c on c.n_cod_cc = e.n_cod_cc and c.conta_caixa
  group by e.data
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
         case when e.contas = (select n from n_caixa) then e.fechamento_ext end as fech_ext,
         f.ent_real, f.sai_real
  from ext e
  full join snap s using (data)
  left join ext_fluxo f on f.data = coalesce(e.data, s.data)
)
select jsonb_build_object(
  'referencia', (select d from hoje),
  'dias', coalesce((
    select jsonb_agg(jsonb_build_object(
      'data',            x.data,
      -- saldo inicial do dia: fechamento − ent + sai (exato pela identidade do
      -- extrato; = fechamento do dia anterior). Fallback foto: saldo das 08:45.
      'abertura',        case when x.fech_ext is not null
                              then round(x.fech_ext - coalesce(x.ent_real, 0) + coalesce(x.sai_real, 0), 2)
                              else x.abertura_foto end,
      'fechamento',      coalesce(x.fech_ext, x.fech_foto),
      'fonte',           case when x.fech_ext is not null then 'extrato'
                              when x.fech_foto is not null then 'foto' end,
      'fechamento_data', case when x.fech_ext is not null then x.data else x.fech_foto_data end,
      'ent_real',        case when x.fech_ext is not null then coalesce(x.ent_real, 0) else x.ent_real end,
      'sai_real',        case when x.fech_ext is not null then coalesce(x.sai_real, 0) else x.sai_real end,
      'movimento',       case when x.fech_ext is not null
                              then round(coalesce(x.ent_real, 0) - coalesce(x.sai_real, 0), 2)
                              else round(x.fech_foto - x.abertura_foto, 2) end,
      'ent_prev',        round(x.ent_prev, 2),
      'sai_prev',        round(x.sai_prev, 2)
    ) order by x.data)
    from dias x, hoje h
    where x.data < h.d and (p_dias is null or x.data >= h.d - p_dias)
  ), '[]'::jsonb)
);
$function$;

comment on function public.fc_historico(int) is
'Dias passados do F.C. Projetado, na visão canônica de caixa: ABERTURA (saldo inicial do dia), ent_real/sai_real (extrato da Omie, contas de caixa; transferência entre duas contas de caixa e linhas Previsto excluídas) e FECHAMENTO (saldo de fim de dia) — identidade exata fech = abertura + ent − sai. Dia sem extrato completo cai na foto do fc_snapshot (fonte=foto). ent_prev/sai_prev = o que a curva projetava (backtest). Default p_dias=NULL = todo o histórico.';
