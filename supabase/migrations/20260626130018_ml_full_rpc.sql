-- Full do mês (linha do card ML): soma detail_amount de ml_full_faturamento por
-- creation_date no mês-calendário. Custo de Fulfillment (armazenamento/coleta/penalidade)
-- — NÃO inclui frete Full (esse já está na linha Frete). É custo por período, não por
-- pedido: sem régua de status. Guarda o dia corrente. SECURITY DEFINER + só service_role.
create or replace function public.ml_full(p_month text)
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'full_total_mes',
    coalesce((
      select round(sum(detail_amount), 2)
      from public.ml_full_faturamento
      where to_char(creation_date, 'YYYY-MM') = p_month
        and creation_date < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$function$;

revoke all on function public.ml_full(text) from public, anon, authenticated;
grant execute on function public.ml_full(text) to service_role;
