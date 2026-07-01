-- ADS do mês (linha do card ML): soma product_ads + brand_ads da ml_ads_diario.
-- Exclui 'seguidores'/CDLIT (fora do escopo). Guarda o dia corrente (não conta dia parcial),
-- mesmo padrão do ml_comissao. SECURITY DEFINER + grant só a service_role.
create or replace function public.ml_ads(p_month text)
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'ads_total_mes',
    coalesce((
      select round(sum(gasto), 2)
      from public.ml_ads_diario
      where to_char(data, 'YYYY-MM') = p_month
        and produto in ('product_ads', 'brand_ads')
        and data < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$function$;

revoke all on function public.ml_ads(text) from public, anon, authenticated;
grant execute on function public.ml_ads(text) to service_role;
