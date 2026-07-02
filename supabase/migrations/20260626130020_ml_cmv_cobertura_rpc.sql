-- Monitoramento da cobertura do CMV: SKUs vendidos (paid+partial) no mês sem custo
-- em ml_custo_produto. Base pro alerta (produto novo entra sem custo → some do CMV).
create or replace function public.ml_cmv_cobertura(p_month text)
returns jsonb
language sql security definer set search_path to 'public'
as $function$
  with base as (
    select i.sku, i.quantidade, i.valor_unitario, c.custo
    from public.ml_pedido_itens i
    join public.ml_pedidos p on p.pedido_id = i.pedido_id
    left join public.ml_custo_produto c on c.sku = i.sku
    where to_char(p.data, 'YYYY-MM') = p_month
      and p.status in ('paid', 'partially_refunded')
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
  )
  select jsonb_build_object(
    'itens', count(*),
    'itens_sem_custo', count(*) filter (where custo is null),
    'skus_sem_custo', count(distinct sku) filter (where custo is null),
    'cobertura_pct', round(100.0 * count(*) filter (where custo is not null) / nullif(count(*), 0), 2),
    'faturamento_descoberto', coalesce(round(sum(valor_unitario * quantidade) filter (where custo is null), 2), 0),
    'skus', coalesce((
      select jsonb_agg(distinct jsonb_build_object('sku', sku) )
      from base where custo is null
    ), '[]'::jsonb)
  )
  from base;
$function$;

revoke all on function public.ml_cmv_cobertura(text) from public, anon, authenticated;
grant execute on function public.ml_cmv_cobertura(text) to service_role;
