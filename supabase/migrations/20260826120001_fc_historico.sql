-- F.C. Projetado: HISTÓRICO — o dia que passou fica visível, com o caixa FECHADO
-- (pedido do Luciano 26/08/2026: "hoje dia 26 não aparece mais o dia anterior;
--  preciso ver o passado, e quando o dia passou o caixa fechou").
--
-- Fonte: fc_snapshot (foto diária das 08:45 BRT, existe desde 25/08/2026).
-- Régua: o FECHAMENTO do dia D = saldo em conta da foto SEGUINTE (a manhã de
-- D+1 captura tudo que entrou/saiu em D). Nada estimado: abertura e fechamento
-- são o saldo real da Omie (fc_saldo_caixa) congelado nas fotos; o movimento do
-- dia é a diferença entre as duas. Se faltar a foto de um dia (cron falhou), o
-- fechamento usa a PRÓXIMA foto existente (`fechamento_data` diz qual) — o dia
-- não some em silêncio, só cobre mais de 24h.
--
-- `ent_prev`/`sai_prev` = o que a curva daquele dia PROJETAVA para D+0 (base do
-- backtest projetado × realizado; a UI pode exibir quando quiser).

create or replace function public.fc_historico(p_dias int default 30)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date as d
),
s as (
  select data,
         saldo_caixa,
         (curva->0->>'entradas')::numeric as ent_prev,  -- curva[0] é sempre D+0
         (curva->0->>'saidas')::numeric   as sai_prev,
         lead(data)        over (order by data) as fechamento_data,
         lead(saldo_caixa) over (order by data) as fechamento
  from public.fc_snapshot
)
select jsonb_build_object(
  'referencia', (select d from hoje),
  'dias', coalesce((
    select jsonb_agg(jsonb_build_object(
      'data',            s.data,
      'abertura',        s.saldo_caixa,
      'fechamento',      s.fechamento,
      'fechamento_data', s.fechamento_data,
      'movimento',       round(s.fechamento - s.saldo_caixa, 2),
      'ent_prev',        round(s.ent_prev, 2),
      'sai_prev',        round(s.sai_prev, 2)
    ) order by s.data)
    from s, hoje h
    where s.data < h.d and s.data >= h.d - p_dias
  ), '[]'::jsonb)
);
$function$;

revoke all on function public.fc_historico(int) from public, anon;
grant execute on function public.fc_historico(int) to service_role, authenticated;
comment on function public.fc_historico(int) is
'Dias passados do F.C. Projetado, com caixa FECHADO: para cada dia com foto em fc_snapshot, abertura = saldo em conta da própria foto e fechamento = saldo da foto seguinte (a manhã de D+1 fecha o dia D). Movimento = diferença real; ent_prev/sai_prev = o que a curva daquele dia projetava para D+0. Histórico acumula desde 25/08/2026.';
