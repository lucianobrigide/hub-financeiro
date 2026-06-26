-- RPCs SECURITY DEFINER que o lib/data/supabase.ts consome (service_role não fura
-- a RLS no SELECT direto via PostgREST). Só números REAIS da bruta; margem/
-- canceladas/devolvidas ficam nulos no provider.

-- Meses que existem nas tabelas (não 12 fixos).
create or replace function public.ml_dashboard_months()
returns setof text
language sql
security definer
set search_path to 'public'
as $function$
  select distinct to_char(data, 'YYYY-MM')
  from public.ml_pedidos
  order by 1 desc;
$function$;
revoke all on function public.ml_dashboard_months() from public, anon, authenticated;
grant execute on function public.ml_dashboard_months() to service_role;

-- Agregação da BRUTA do mês (fuso SP, exclui dia corrente e status 'invalid').
create or replace function public.ml_dashboard(p_month text)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  with base as (
    select *
    from public.ml_pedidos
    where to_char(data, 'YYYY-MM') = p_month
      and status <> 'invalid'
      and data < (now() at time zone 'America/Sao_Paulo')::date
  ),
  diaria as (
    select data, sum(valor_total) as v, count(*) as q
    from base group by data
  )
  select jsonb_build_object(
    'totalVenda',   coalesce((select sum(valor_total) from base), 0),
    'totalPedidos', (select count(*) from base),
    'diasComVenda', (select count(distinct data) from base),
    'diasNoMes',    extract(day from (date_trunc('month', (p_month||'-01')::date) + interval '1 month' - interval '1 day'))::int,
    'vendasDiarias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', to_char(data,'DD/MM'), 'valor', v, 'pedidos', q) order by data desc)
       from diaria), '[]'::jsonb)
  );
$function$;
revoke all on function public.ml_dashboard(text) from public, anon, authenticated;
grant execute on function public.ml_dashboard(text) to service_role;
