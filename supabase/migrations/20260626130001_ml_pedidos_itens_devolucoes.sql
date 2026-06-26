-- Módulo 02 — tabelas de ingestão de pedidos do Mercado Livre.
-- data = date_closed convertido para America/Sao_Paulo. Sem coluna 'familia'
-- (as famílias são agregação em SQL). RLS ligado sem policies.
create table if not exists public.ml_pedidos (
  pedido_id          bigint primary key,
  data               date        not null,
  date_closed        timestamptz,
  date_created       timestamptz,
  status             text        not null,
  valor_total        numeric(14,2),
  valor_reembolsado  numeric(14,2) not null default 0,
  qtd_unidades       integer,
  canal              text,
  moeda              text,
  date_last_updated  timestamptz,
  atualizado_em      timestamptz not null default now()
);
create index if not exists ml_pedidos_data_idx   on public.ml_pedidos (data);
create index if not exists ml_pedidos_status_idx on public.ml_pedidos (status);
create index if not exists ml_pedidos_dlu_idx    on public.ml_pedidos (date_last_updated);

create table if not exists public.ml_pedido_itens (
  pedido_id      bigint not null references public.ml_pedidos(pedido_id) on delete cascade,
  item_id        text   not null,
  variation_id   bigint not null default 0,
  sku            text,
  titulo         text,
  quantidade     integer,
  valor_unitario numeric(14,2),
  sale_fee       numeric(14,2),
  moeda          text,
  primary key (pedido_id, item_id, variation_id)
);

create table if not exists public.ml_devolucoes (
  claim_id           bigint primary key,
  order_id           bigint references public.ml_pedidos(pedido_id),
  return_id          bigint,
  tipo               text,
  reason_id          text,
  claim_status       text,
  resolution_reason  text,
  status_money       text,
  qtd_devolvida      numeric,
  valor_reembolsado  numeric(14,2),
  date_created       timestamptz,
  last_updated       timestamptz,
  atualizado_em      timestamptz not null default now()
);
create index if not exists ml_devolucoes_order_idx on public.ml_devolucoes (order_id);
create index if not exists ml_devolucoes_money_idx on public.ml_devolucoes (status_money);

alter table public.ml_pedidos      enable row level security;
alter table public.ml_pedido_itens enable row level security;
alter table public.ml_devolucoes   enable row level security;
