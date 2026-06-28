-- Custo Full por mês, lido da ml_full_faturamento. SECURITY DEFINER (tabela tem RLS;
-- service_role não fura via PostgREST). Atribui pela DATA DO CUSTO (creation_date), que
-- é o dia real do lançamento — NÃO pela KEY do período de faturamento (o ciclo mistura
-- 2 meses). Filtra creation_date ∈ mês. Soma total + quebra por tipo.
create or replace function public.ml_full_custo(p_month text)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  with base as (
    select tipo, detail_amount
    from public.ml_full_faturamento
    where to_char(creation_date, 'YYYY-MM') = p_month
  ),
  por_tipo as (
    select coalesce(tipo, 'SEM_TIPO') as tipo,
           count(*)                   as lancamentos,
           round(sum(detail_amount), 2) as custo
    from base
    group by coalesce(tipo, 'SEM_TIPO')
  )
  select jsonb_build_object(
    'custo_full_total_mes', coalesce((select round(sum(detail_amount), 2) from base), 0),
    'lancamentos_total',    (select count(*) from base),
    'por_tipo', coalesce(
      (select jsonb_agg(jsonb_build_object(
         'tipo', tipo, 'lancamentos', lancamentos, 'custo', custo
       ) order by custo desc)
       from por_tipo), '[]'::jsonb)
  );
$function$;
revoke all on function public.ml_full_custo(text) from public, anon, authenticated;
grant execute on function public.ml_full_custo(text) to service_role;
