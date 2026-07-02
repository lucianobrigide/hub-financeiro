-- RPCs de escrita p/ os novos passos da Edge (ADS/Full/Frete). Padrão: SECURITY DEFINER,
-- só service_role. A Edge nunca usa PAT/Management API.

-- ADS: upsert (data,produto,gasto)
create or replace function public.ml_upsert_ads(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_ads_diario (data, produto, gasto)
  select r.data, r.produto, r.gasto
  from jsonb_to_recordset(p_rows) as r(data date, produto text, gasto numeric)
  on conflict (data, produto) do update set gasto = excluded.gasto, atualizado_em = now();
  get diagnostics n = row_count; return n;
end $$;

-- FULL: upsert por detail_id
create or replace function public.ml_upsert_full(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_full_faturamento
    (detail_id, creation_date, creation_date_time, tipo, detail_sub_type, detail_amount,
     transaction_detail, concept_type, warehouse_id, sku, item_id, inventory_id, quantity,
     amount_per_unit, legal_document_number, document_id, periodo_key)
  select r.detail_id, r.creation_date, r.creation_date_time, r.tipo, r.detail_sub_type, r.detail_amount,
     r.transaction_detail, r.concept_type, r.warehouse_id, r.sku, r.item_id, r.inventory_id, r.quantity,
     r.amount_per_unit, r.legal_document_number, r.document_id, r.periodo_key
  from jsonb_to_recordset(p_rows) as r(
     detail_id bigint, creation_date date, creation_date_time timestamptz, tipo text,
     detail_sub_type text, detail_amount numeric, transaction_detail text, concept_type text,
     warehouse_id text, sku text, item_id text, inventory_id text, quantity numeric,
     amount_per_unit numeric, legal_document_number text, document_id bigint, periodo_key date)
  on conflict (detail_id) do update set
     creation_date=excluded.creation_date, creation_date_time=excluded.creation_date_time,
     tipo=excluded.tipo, detail_sub_type=excluded.detail_sub_type, detail_amount=excluded.detail_amount,
     transaction_detail=excluded.transaction_detail, concept_type=excluded.concept_type,
     warehouse_id=excluded.warehouse_id, sku=excluded.sku, item_id=excluded.item_id,
     inventory_id=excluded.inventory_id, quantity=excluded.quantity, amount_per_unit=excluded.amount_per_unit,
     legal_document_number=excluded.legal_document_number, document_id=excluded.document_id,
     periodo_key=excluded.periodo_key, atualizado_em=now();
  get diagnostics n = row_count; return n;
end $$;

-- ENVIOS (frete): upsert por shipment_id
create or replace function public.ml_upsert_envios(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.ml_envios
    (shipment_id, custo_vendedor, custo_comprador, gross_amount, logistic_type, cost_type, status, last_updated)
  select r.shipment_id, r.custo_vendedor, r.custo_comprador, r.gross_amount, r.logistic_type, r.cost_type, r.status, r.last_updated
  from jsonb_to_recordset(p_rows) as r(
     shipment_id bigint, custo_vendedor numeric, custo_comprador numeric, gross_amount numeric,
     logistic_type text, cost_type text, status text, last_updated timestamptz)
  on conflict (shipment_id) do update set
     custo_vendedor=excluded.custo_vendedor, custo_comprador=excluded.custo_comprador,
     gross_amount=excluded.gross_amount, logistic_type=excluded.logistic_type,
     cost_type=excluded.cost_type, status=excluded.status, last_updated=excluded.last_updated,
     atualizado_em=now();
  get diagnostics n = row_count; return n;
end $$;

-- shipping_id/pack_id nos pedidos (frete fase A / fechar)
create or replace function public.ml_set_shipping_ids(p_rows jsonb)
returns integer language plpgsql security definer set search_path to 'public'
as $$
declare n integer;
begin
  update public.ml_pedidos p set shipping_id = v.sid, pack_id = v.pid
  from jsonb_to_recordset(p_rows) as v(pedido_id bigint, sid bigint, pid bigint)
  where p.pedido_id = v.pedido_id;
  get diagnostics n = row_count; return n;
end $$;

-- shipping_ids da janela trailing que ainda NÃO estão em ml_envios (frete pendente, chunked)
create or replace function public.ml_frete_pendentes(p_from date, p_limit integer)
returns bigint[] language sql security definer set search_path to 'public'
as $$
  select coalesce(array_agg(sid), '{}')
  from (
    select distinct p.shipping_id as sid
    from public.ml_pedidos p
    left join public.ml_envios e on e.shipment_id = p.shipping_id
    where p.data >= p_from and p.status in ('paid','partially_refunded')
      and p.shipping_id is not null and e.shipment_id is null
    order by 1 limit p_limit
  ) q;
$$;

revoke all on function public.ml_upsert_ads(jsonb) from public, anon, authenticated;
revoke all on function public.ml_upsert_full(jsonb) from public, anon, authenticated;
revoke all on function public.ml_upsert_envios(jsonb) from public, anon, authenticated;
revoke all on function public.ml_set_shipping_ids(jsonb) from public, anon, authenticated;
revoke all on function public.ml_frete_pendentes(date, integer) from public, anon, authenticated;
grant execute on function public.ml_upsert_ads(jsonb) to service_role;
grant execute on function public.ml_upsert_full(jsonb) to service_role;
grant execute on function public.ml_upsert_envios(jsonb) to service_role;
grant execute on function public.ml_set_shipping_ids(jsonb) to service_role;
grant execute on function public.ml_frete_pendentes(date, integer) to service_role;
