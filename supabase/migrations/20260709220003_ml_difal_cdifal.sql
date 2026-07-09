-- ============================================================
-- ML DIFAL (CDIFAL) — "Cobrança do diferencial de alíquota interestadual (ICMS-DIFAL)"
-- Imposto sobre venda interestadual, cobrado na fatura do ML (marketplace=SHIPPING),
-- via billing:
--   GET /billing/integration/periods/key/{YYYY-MM-01}/group/ML/details
--       ?document_type=BILL&detail_sub_types=CDIFAL
--
-- NATUREZA (decisão consciente — igual Full/Afiliado):
--   Régua = creation_date (dia da cobrança na fatura), mês-calendário. DIFAL é DIÁRIO
--   (per-envio), não batched. O ciclo de billing ~fecha dia 22, então junho-calendário
--   vem de 2 faturas (junho: creation 01-22; julho: creation 23-30) — ingest pesca
--   mesKey(0)+mesKey(-1), igual Full/Afiliado. Tratado como DEDUÇÃO da M.C. (7ª linha).
--   Zero dupla contagem: CDIFAL é tipo separado; nosso Frete vem de /shipments/costs,
--   não do billing. Carga tributária completa fica pro módulo Impostos futuro.
--   Junho/2026: 1.770 cobranças = R$ 55.086,25.
-- ============================================================

create table if not exists public.ml_difal (
  detail_id             bigint primary key,            -- charge_info.detail_id (idempotência)
  creation_date         date,                          -- date(creation_date_time) — dia da cobrança
  creation_date_time    timestamptz,                   -- charge_info.creation_date_time
  detail_sub_type       text,                          -- charge_info.detail_sub_type (CDIFAL)
  detail_amount         numeric(14,2),                 -- charge_info.detail_amount (R$)
  transaction_detail    text,                          -- charge_info.transaction_detail
  order_id              bigint,                        -- sales_info[0].order_id
  sale_date_time        timestamptz,                   -- sales_info[0].sale_date_time
  marketplace           text,                          -- marketplace_info.marketplace (SHIPPING)
  legal_document_number text,                          -- charge_info.legal_document_number
  document_id           bigint,                        -- document_info.document_id
  periodo_key           date,                          -- a KEY consultada (YYYY-MM-01)
  atualizado_em         timestamptz not null default now()
);
alter table public.ml_difal enable row level security;
create index if not exists ml_difal_creation_date_idx on public.ml_difal (creation_date);
create index if not exists ml_difal_periodo_idx       on public.ml_difal (periodo_key);

-- UPSERT por detail_id (idempotente; ingest pesca de 2 faturas sem overlap)
create or replace function public.ml_upsert_difal(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_difal
    (detail_id, creation_date, creation_date_time, detail_sub_type, detail_amount,
     transaction_detail, order_id, sale_date_time, marketplace, legal_document_number, document_id, periodo_key)
  select r.detail_id, r.creation_date, r.creation_date_time, r.detail_sub_type, r.detail_amount,
     r.transaction_detail, r.order_id, r.sale_date_time, r.marketplace, r.legal_document_number, r.document_id, r.periodo_key
  from jsonb_to_recordset(p_rows) as r(
     detail_id bigint, creation_date date, creation_date_time timestamptz, detail_sub_type text,
     detail_amount numeric, transaction_detail text, order_id bigint, sale_date_time timestamptz,
     marketplace text, legal_document_number text, document_id bigint, periodo_key date)
  on conflict (detail_id) do update set
     creation_date=excluded.creation_date, creation_date_time=excluded.creation_date_time,
     detail_sub_type=excluded.detail_sub_type, detail_amount=excluded.detail_amount,
     transaction_detail=excluded.transaction_detail, order_id=excluded.order_id,
     sale_date_time=excluded.sale_date_time, marketplace=excluded.marketplace,
     legal_document_number=excluded.legal_document_number, document_id=excluded.document_id,
     periodo_key=excluded.periodo_key, atualizado_em=now();
  get diagnostics n = row_count; return n;
end $$;

-- DIFAL do mês (7ª dedução do card ML): soma detail_amount por creation_date no
-- mês-calendário. Régua = creation_date (paridade com ml_full/sp_afiliados_ml).
create or replace function public.sp_difal_ml(p_month text)
returns jsonb language sql security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'difal_total_mes',
    coalesce((
      select round(sum(detail_amount), 2)
      from public.ml_difal
      where to_char(creation_date, 'YYYY-MM') = p_month
        and creation_date < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$$;

revoke all on function public.ml_upsert_difal(jsonb) from public, anon, authenticated;
revoke all on function public.sp_difal_ml(text)      from public, anon, authenticated;
grant execute on function public.ml_upsert_difal(jsonb) to service_role;
grant execute on function public.sp_difal_ml(text)      to service_role;
