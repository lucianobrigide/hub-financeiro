-- Comissão por mês aplicando sale_fee × quantidade NA LEITURA (sale_fee permanece
-- cru, por unidade, em ml_pedido_itens — nada é repopulado). SECURITY DEFINER
-- (tabelas têm RLS; service_role não fura via PostgREST). Fuso America/Sao_Paulo;
-- junta ml_pedido_itens a ml_pedidos pela data da venda; exclui status 'invalid' e
-- o dia corrente.
create or replace function public.ml_comissao(p_month text)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  with base as (
    select i.sku, i.titulo, i.quantidade, i.valor_unitario, i.sale_fee
    from public.ml_pedido_itens i
    join public.ml_pedidos p on p.pedido_id = i.pedido_id
    where to_char(p.data, 'YYYY-MM') = p_month
      and p.status <> 'invalid'
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
  ),
  por_sku as (
    select
      sku,
      max(titulo)                                                              as titulo,
      sum(quantidade)                                                          as qtd_vendida,
      round(sum(valor_unitario * quantidade), 2)                               as faturamento,
      round(sum(sale_fee * quantidade), 2)                                     as comissao,
      round(100.0 * sum(sale_fee * quantidade) / nullif(sum(valor_unitario * quantidade), 0), 2) as comissao_pct
    from base
    group by sku
  )
  select jsonb_build_object(
    'comissao_total_mes', coalesce((select round(sum(sale_fee * quantidade), 2) from base), 0),
    'por_sku', coalesce(
      (select jsonb_agg(jsonb_build_object(
         'sku', sku, 'titulo', titulo, 'qtd_vendida', qtd_vendida,
         'faturamento', faturamento, 'comissao', comissao, 'comissao_pct', comissao_pct
       ) order by comissao desc)
       from por_sku), '[]'::jsonb)
  );
$function$;
revoke all on function public.ml_comissao(text) from public, anon, authenticated;
grant execute on function public.ml_comissao(text) to service_role;
