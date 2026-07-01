-- RPCs de escrita do motor de ingestão (Edge ml-ingest-dia). Padrão ml-token:
-- SECURITY DEFINER + grant só a service_role (o Edge chama via PostgREST/service_key).
-- Reproduzem o UPSERT idempotente dos scripts cron_lib.mjs. shipping_id/pack_id NÃO
-- entram no INSERT/UPDATE (preservados, como no script).

create or replace function public.ml_upsert_pedidos(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_pedidos
    (pedido_id, data, date_closed, date_created, status, valor_total,
     valor_reembolsado, qtd_unidades, canal, moeda, date_last_updated, data_cancelamento)
  select r.pedido_id, r.data, r.date_closed, r.date_created, r.status, r.valor_total,
     coalesce(r.valor_reembolsado,0), r.qtd_unidades, r.canal, r.moeda, r.date_last_updated, r.data_cancelamento
  from jsonb_to_recordset(p_rows) as r(
    pedido_id bigint, data date, date_closed timestamptz, date_created timestamptz, status text,
    valor_total numeric, valor_reembolsado numeric, qtd_unidades integer, canal text, moeda text,
    date_last_updated timestamptz, data_cancelamento date)
  on conflict (pedido_id) do update set
    data=excluded.data, date_closed=excluded.date_closed, date_created=excluded.date_created,
    status=excluded.status, valor_total=excluded.valor_total, valor_reembolsado=excluded.valor_reembolsado,
    qtd_unidades=excluded.qtd_unidades, canal=excluded.canal, moeda=excluded.moeda,
    date_last_updated=excluded.date_last_updated, data_cancelamento=excluded.data_cancelamento,
    atualizado_em=now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.ml_upsert_itens(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_pedido_itens
    (pedido_id, item_id, variation_id, sku, titulo, quantidade, valor_unitario, sale_fee, moeda)
  select r.pedido_id, r.item_id, coalesce(r.variation_id,0), r.sku, r.titulo,
     r.quantidade, r.valor_unitario, r.sale_fee, r.moeda
  from jsonb_to_recordset(p_rows) as r(
    pedido_id bigint, item_id text, variation_id bigint, sku text, titulo text,
    quantidade integer, valor_unitario numeric, sale_fee numeric, moeda text)
  on conflict (pedido_id, item_id, variation_id) do update set
    sku=excluded.sku, titulo=excluded.titulo, quantidade=excluded.quantidade,
    valor_unitario=excluded.valor_unitario, sale_fee=excluded.sale_fee, moeda=excluded.moeda;
  get diagnostics n = row_count;
  return n;
end $$;

-- Leitura do estado ATUAL (status/reembolso) das linhas existentes — base do
-- "antes" do reconferir (update-only). Recebe array de pedido_id.
create or replace function public.ml_pedidos_estado(p_ids bigint[])
returns table(pedido_id bigint, status text, valor_reembolsado numeric)
language sql security definer set search_path to 'public'
as $$
  select pedido_id, status, valor_reembolsado
  from public.ml_pedidos
  where pedido_id = any(p_ids);
$$;

revoke all on function public.ml_upsert_pedidos(jsonb) from public, anon, authenticated;
revoke all on function public.ml_upsert_itens(jsonb) from public, anon, authenticated;
revoke all on function public.ml_pedidos_estado(bigint[]) from public, anon, authenticated;
grant execute on function public.ml_upsert_pedidos(jsonb) to service_role;
grant execute on function public.ml_upsert_itens(jsonb) to service_role;
grant execute on function public.ml_pedidos_estado(bigint[]) to service_role;
