-- Atribuição de cancelamento pela DATA DO EVENTO (não pela data da venda).
-- data_cancelamento = cancel_detail.date @ America/Sao_Paulo (null se não cancelado).
alter table public.ml_pedidos
  add column if not exists data_cancelamento date;
create index if not exists ml_pedidos_datacancel_idx on public.ml_pedidos (data_cancelamento);
