-- Custo Full (Fulfillment) vindo do billing:
--   GET /billing/integration/periods/key/{YYYY-MM-01}/group/ML/full/details?document_type=BILL
-- Guarda TODOS os tipos (WAREHOUSING/INBOUND_COLLECT/INBOUND_PENALTY/AGING/...); o filtro
-- por tipo e por dia é feito NA LEITURA. Atribuição por DATA DO CUSTO = creation_date_time
-- (diário). Cuidado: a KEY do período cobre o ciclo de faturamento (~23 do mês anterior a
-- 22 do mês da KEY), então a mesma tabela mistura dias de 2 meses — por isso guardamos
-- periodo_key (a KEY consultada) e creation_date (o dia real do custo) separados.
create table if not exists public.ml_full_faturamento (
  detail_id             bigint primary key,           -- charge_info.detail_id (idempotência)
  creation_date         date,                         -- date(creation_date_time) — dia do custo
  creation_date_time    timestamptz,                  -- charge_info.creation_date_time
  tipo                  text,                          -- fulfillment_info.type
  detail_sub_type       text,                          -- charge_info.detail_sub_type
  detail_amount         numeric(14,2),                 -- charge_info.detail_amount (R$)
  transaction_detail    text,                          -- charge_info.transaction_detail
  concept_type          text,                          -- charge_info.concept_type
  warehouse_id          text,                          -- fulfillment_info.warehouse_id
  sku                   text,                          -- fulfillment_info.sku (null em WAREHOUSING)
  item_id               text,                          -- fulfillment_info.item_id
  inventory_id          text,                          -- fulfillment_info.inventory_id
  quantity              numeric,                       -- fulfillment_info.quantity
  amount_per_unit       numeric(14,6),                 -- fulfillment_info.amount_per_unit
  legal_document_number text,                          -- charge_info.legal_document_number (a NF)
  document_id           bigint,                        -- document_info.document_id
  periodo_key           date,                          -- a KEY consultada (YYYY-MM-01)
  atualizado_em         timestamptz not null default now()
);
alter table public.ml_full_faturamento enable row level security;
create index if not exists ml_full_fat_creation_date_idx on public.ml_full_faturamento (creation_date);
create index if not exists ml_full_fat_tipo_idx          on public.ml_full_faturamento (tipo);
create index if not exists ml_full_fat_periodo_idx       on public.ml_full_faturamento (periodo_key);
