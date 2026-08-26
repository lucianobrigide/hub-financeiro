-- F.C. Projetado: histórico SEM teto (pedido do Luciano 26/08/2026: "não pode
-- ser só até 30 dias — preciso sempre conseguir ver todo o histórico").
--
-- A versão de 20260826120001 limitava a janela a p_dias=30 por default. Agora
-- o default é NULL = TODO o histórico desde a primeira foto do fc_snapshot
-- (25/08/2026). O parâmetro continua existindo para quem quiser recortar.
-- Régua inalterada: fechamento do dia D = saldo_caixa da foto seguinte.

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
    where s.data < h.d and (p_dias is null or s.data >= h.d - p_dias)
  ), '[]'::jsonb)
);
$function$;

revoke all on function public.fc_historico(int) from public, anon;
grant execute on function public.fc_historico(int) to service_role, authenticated;
comment on function public.fc_historico(int) is
'Dias passados do F.C. Projetado, com caixa FECHADO: para cada dia com foto em fc_snapshot, abertura = saldo em conta da própria foto e fechamento = saldo da foto seguinte (a manhã de D+1 fecha o dia D). Movimento = diferença real; ent_prev/sai_prev = o que a curva daquele dia projetava para D+0. Default p_dias=NULL devolve TODO o histórico (acumula desde 25/08/2026); passe um número para recortar.';
