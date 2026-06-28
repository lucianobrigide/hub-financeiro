-- Frete por ENVIO (shipment). custo_vendedor = senders[].cost do nosso user
-- (= linha "Envios" do painel). Frete é por envio, não por unidade.
-- Fonte: GET /shipments/{id}/costs (x-format-new: true) + GET /shipments/{id}.
create table if not exists public.ml_envios (
  shipment_id      bigint primary key,
  custo_vendedor   numeric(14,2),   -- senders[].cost do user 494625660
  custo_comprador  numeric(14,2),   -- receiver.cost
  gross_amount     numeric(14,2),
  logistic_type    text,
  cost_type        text,            -- free | charged | partially_free
  status           text,
  last_updated     timestamptz,
  atualizado_em    timestamptz not null default now()
);
alter table public.ml_envios enable row level security;

-- Ligação pedido -> envio / carrinho (capturados de order.shipping.id e order.pack_id).
alter table public.ml_pedidos
  add column if not exists shipping_id bigint,
  add column if not exists pack_id     bigint;
create index if not exists ml_pedidos_shipping_idx on public.ml_pedidos (shipping_id);
