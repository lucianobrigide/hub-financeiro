-- CMV do mês (linha do card ML): casa ml_custo_produto por SKU em ml_pedido_itens,
-- custo × quantidade. Régua da margem: paid + partially_refunded (exclui cancelled),
-- por date_closed@SP (coluna data), guarda o dia corrente. SECURITY DEFINER + só service_role.
create or replace function public.ml_cmv(p_month text)
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'cmv_total_mes',
    coalesce((
      select round(sum(c.custo * i.quantidade), 2)
      from public.ml_pedido_itens i
      join public.ml_pedidos p on p.pedido_id = i.pedido_id
      join public.ml_custo_produto c on c.sku = i.sku
      where to_char(p.data, 'YYYY-MM') = p_month
        and p.status in ('paid', 'partially_refunded')
        and p.data < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$function$;

revoke all on function public.ml_cmv(text) from public, anon, authenticated;
grant execute on function public.ml_cmv(text) to service_role;
