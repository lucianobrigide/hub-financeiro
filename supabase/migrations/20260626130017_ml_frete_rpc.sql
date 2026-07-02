-- Frete do mês (linha do card ML): soma custo_vendedor de ml_envios ligado ao pedido por
-- shipping_id. Régua da margem: paid + partially_refunded (exclui cancelled), por
-- date_closed@SP (coluna data), guarda o dia corrente. Frete de ENTREGA (sem devolução:
-- ml_envios só tem os shipments de ida). Mesmo padrão de ml_comissao/ml_ads.
create or replace function public.ml_frete(p_month text)
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'frete_total_mes',
    coalesce((
      select round(sum(e.custo_vendedor), 2)
      from public.ml_pedidos p
      join public.ml_envios e on e.shipment_id = p.shipping_id
      where to_char(p.data, 'YYYY-MM') = p_month
        and p.status in ('paid', 'partially_refunded')
        and p.data < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$function$;

revoke all on function public.ml_frete(text) from public, anon, authenticated;
grant execute on function public.ml_frete(text) to service_role;
