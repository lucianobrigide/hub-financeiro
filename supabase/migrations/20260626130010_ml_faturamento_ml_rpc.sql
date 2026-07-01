-- Faturamento do card Mercado Livre (3 linhas de topo do mini-DRE), por mês.
-- SECURITY DEFINER (ml_pedidos tem RLS; service_role não fura via PostgREST).
-- Régua: base = pedidos paid + cancelled + partially_refunded (exclui 'invalid').
--   faturamentoBruto   = Σ valor_total de TODA a base
--   cancelDevolucoes   = Σ valor_total dos cancelled (inteiro)
--                        + Σ valor_reembolsado dos partially_refunded (só a porção)
--   faturamentoLiquido = bruto − cancelDevolucoes
-- Atribuição ao mês pela data da venda (ml_pedidos.data, já em America/Sao_Paulo).
-- Deduções e M.C. NÃO entram aqui — o RPC de margem está travado.
create or replace function public.ml_faturamento_ml(p_month text)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  with agg as (
    select
      coalesce(sum(valor_total), 0)                                                    as bruto,
      coalesce(sum(valor_total) filter (where status = 'cancelled'), 0)                as cancel_total,
      coalesce(sum(valor_reembolsado) filter (where status = 'partially_refunded'), 0) as parc_reemb
    from public.ml_pedidos
    where to_char(data, 'YYYY-MM') = p_month
      and status in ('paid', 'cancelled', 'partially_refunded')
  )
  select jsonb_build_object(
    'faturamentoBruto',   round(bruto, 2),
    'cancelDevolucoes',   round(cancel_total + parc_reemb, 2),
    'faturamentoLiquido', round(bruto - cancel_total - parc_reemb, 2)
  )
  from agg;
$function$;
revoke all on function public.ml_faturamento_ml(text) from public, anon, authenticated;
grant execute on function public.ml_faturamento_ml(text) to service_role;
