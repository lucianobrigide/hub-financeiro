-- Adiciona totalPedidosValidos ao ml_dashboard (paid + partially_refunded, sem cancelados).
-- Usado no KPI "Total de Pedidos" do topo (negócio inteiro, régua consistente com o DRE).
CREATE OR REPLACE FUNCTION public.ml_dashboard(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select *
    from public.ml_pedidos
    where to_char(data, 'YYYY-MM') = p_month
      and status <> 'invalid'
      and data < (now() at time zone 'America/Sao_Paulo')::date   -- exclui o dia corrente (SP)
  ),
  diaria as (
    select data, sum(valor_total) as v, count(*) as q
    from base group by data
  )
  select jsonb_build_object(
    'totalVenda',   coalesce((select sum(valor_total) from base), 0),
    'totalPedidos', (select count(*) from base),
    'totalPedidosValidos', (select count(*) from base where status in ('paid','partially_refunded')),
    'diasComVenda', (select count(distinct data) from base),
    'diasNoMes',    extract(day from (date_trunc('month', (p_month||'-01')::date) + interval '1 month' - interval '1 day'))::int,
    'vendasDiarias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', to_char(data,'DD/MM'), 'valor', v, 'pedidos', q) order by data desc)
       from diaria), '[]'::jsonb)
  );
$function$;
