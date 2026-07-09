-- ============================================================
-- ML Afiliados (CVAF) — "Cargo por venta con afiliados"
-- Custo do programa de afiliados do ML, vindo do billing:
--   GET /billing/integration/periods/key/{YYYY-MM-01}/group/ML/details
--       ?document_type=BILL&detail_sub_types=CVAF
--
-- NATUREZA DA LINHA (decisão consciente — igual ao Full):
--   Atribuição por creation_date (dia em que o ML LANÇOU a cobrança na fatura),
--   NÃO por data da venda. As cobranças CVAF são criadas em LOTE, meses depois da
--   venda original (sale_date jan-abr -> creation_date jun). Logo os ~R$33k de junho
--   são de vendas ANTIGAS que o ML cobrou com atraso. Bate com a FATURA do ML, mas
--   descasa da competência das vendas de junho. Régua: creation_date no mês-calendário
--   (regime de quando o ML cobra), pescando de TODAS as faturas que tocam o mês (o
--   ciclo ~fecha dia 15, então junho-calendário vem das faturas de junho E julho —
--   ingest puxa mesKey(0) e mesKey(-1), igual Full).
--
-- Ingest: modo 'afiliados' da Edge ml-ingest-dia (ingestAfiliados). Paginação por
--   detail_id do ÚLTIMO registro (o j.last_id do /details pula à frente e derruba
--   registros no fim da página). Idempotente por detail_id — as 2 faturas não têm
--   overlap. Junho/2026: 2.503 registros = R$ 33.098,17 (bate com a fatura R$ 33.047,80;
--   dif R$50 = R$59 de 24/jun na fatura de julho menos R$8 de 27/mai excluído).
-- ============================================================

create table if not exists public.ml_afiliados (
  detail_id             bigint primary key,            -- charge_info.detail_id (idempotência)
  creation_date         date,                          -- date(creation_date_time) — dia da cobrança
  creation_date_time    timestamptz,                   -- charge_info.creation_date_time
  detail_sub_type       text,                          -- charge_info.detail_sub_type (CVAF)
  detail_amount         numeric(14,2),                 -- charge_info.detail_amount (R$)
  transaction_detail    text,                          -- charge_info.transaction_detail
  order_id              bigint,                        -- sales_info[0].order_id
  sale_date_time        timestamptz,                   -- sales_info[0].sale_date_time (venda original)
  legal_document_number text,                          -- charge_info.legal_document_number (a NF)
  document_id           bigint,                        -- document_info.document_id
  periodo_key           date,                          -- a KEY consultada (YYYY-MM-01)
  atualizado_em         timestamptz not null default now()
);
alter table public.ml_afiliados enable row level security;
create index if not exists ml_afiliados_creation_date_idx on public.ml_afiliados (creation_date);
create index if not exists ml_afiliados_periodo_idx       on public.ml_afiliados (periodo_key);

-- UPSERT por detail_id (idempotente; ingest pesca de 2 faturas sem overlap)
create or replace function public.ml_upsert_afiliados(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_afiliados
    (detail_id, creation_date, creation_date_time, detail_sub_type, detail_amount,
     transaction_detail, order_id, sale_date_time, legal_document_number, document_id, periodo_key)
  select r.detail_id, r.creation_date, r.creation_date_time, r.detail_sub_type, r.detail_amount,
     r.transaction_detail, r.order_id, r.sale_date_time, r.legal_document_number, r.document_id, r.periodo_key
  from jsonb_to_recordset(p_rows) as r(
     detail_id bigint, creation_date date, creation_date_time timestamptz, detail_sub_type text,
     detail_amount numeric, transaction_detail text, order_id bigint, sale_date_time timestamptz,
     legal_document_number text, document_id bigint, periodo_key date)
  on conflict (detail_id) do update set
     creation_date=excluded.creation_date, creation_date_time=excluded.creation_date_time,
     detail_sub_type=excluded.detail_sub_type, detail_amount=excluded.detail_amount,
     transaction_detail=excluded.transaction_detail, order_id=excluded.order_id,
     sale_date_time=excluded.sale_date_time, legal_document_number=excluded.legal_document_number,
     document_id=excluded.document_id, periodo_key=excluded.periodo_key, atualizado_em=now();
  get diagnostics n = row_count; return n;
end $$;

-- Afiliados do mês (linha do card ML): soma detail_amount por creation_date no
-- mês-calendário. Régua Opção A (creation_date = quando o ML cobra). Guarda o dia
-- corrente (paridade com ml_full). SECURITY DEFINER + só service_role.
create or replace function public.sp_afiliados_ml(p_month text)
returns jsonb language sql security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'afiliados_total_mes',
    coalesce((
      select round(sum(detail_amount), 2)
      from public.ml_afiliados
      where to_char(creation_date, 'YYYY-MM') = p_month
        and creation_date < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$$;

revoke all on function public.ml_upsert_afiliados(jsonb) from public, anon, authenticated;
revoke all on function public.sp_afiliados_ml(text)      from public, anon, authenticated;
grant execute on function public.ml_upsert_afiliados(jsonb) to service_role;
grant execute on function public.sp_afiliados_ml(text)      to service_role;
