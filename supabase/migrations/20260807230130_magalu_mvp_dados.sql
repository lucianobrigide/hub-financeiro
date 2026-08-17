-- MAGALU MVP — pedidos + itens (shape minimo + raw, padrao SHEIN) e cards.
-- Fonte: GET https://api.magalu.com/seller/v1/orders (paginado _offset/_limit).
-- Valores da API vem em centavos: valor_real = total / normalizer (default 100).
-- Regua do card: bruta = amounts.total PAGO pelo cliente (pos-desconto), status <> cancelled,
-- competencia created_at BRT. Comissao/frete REAIS por pedido. Desconto e informativo
-- (ja embutido na bruta — NAO e deducao).

create table public.magalu_pedidos (
  code        text primary key,
  status      text,
  created_at  timestamptz,
  approved_at timestamptz,
  valor_total numeric,
  comissao    numeric,
  frete       numeric,
  desconto    numeric,
  currency    text,
  raw         jsonb,
  inserted_at timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table public.magalu_pedidos is
  'Pedidos MAGALU via /seller/v1/orders (MVP — shape minimo + raw; valores ja normalizados de centavos para reais). Status: new|approved|cancelled|finished.';
alter table public.magalu_pedidos enable row level security;
create index magalu_pedidos_created_idx on public.magalu_pedidos (created_at);

create table public.magalu_itens (
  code         text not null,
  linha        integer not null,
  sku          text,
  product_name text,
  quantity     integer,
  unit_price   numeric,
  raw          jsonb,
  primary key (code, linha)
);
comment on table public.magalu_itens is
  'Itens dos pedidos MAGALU (achatados de deliveries[].items[]). unit_price ja em reais.';
alter table public.magalu_itens enable row level security;

-- ingestao de uma pagina; retorna quantos pedidos processou
create or replace function public.magalu_ingest_page(p_gte date, p_lte date, p_offset integer default 0, p_limit integer default 100)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_resp jsonb; v_results jsonb; v_ped jsonb; v_item jsonb;
  v_norm numeric; v_linha int; v_n int := 0;
begin
  v_resp := public.magalu_api_get(
    '/seller/v1/orders'
    || '?purchased_at__gte=' || p_gte::text
    || '&purchased_at__lte=' || (p_lte + 1)::text
    || '&_limit='  || p_limit
    || '&_offset=' || p_offset
    || '&_sort=purchased_at:asc');

  if (v_resp->>'status')::int <> 200 then
    return jsonb_build_object('ok', false, 'error', 'http_' || (v_resp->>'status'), 'detail', v_resp->'body');
  end if;

  v_results := v_resp->'body'->'results';
  if v_results is null or jsonb_typeof(v_results) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'sem_results', 'detail', v_resp->'body');
  end if;

  for v_ped in select * from jsonb_array_elements(v_results) loop
    v_norm := coalesce(nullif(v_ped->'amounts'->>'normalizer','')::numeric, 100);

    insert into public.magalu_pedidos as t
      (code, status, created_at, approved_at, valor_total, comissao, frete, desconto, currency, raw, updated_at)
    values (
      v_ped->>'code',
      v_ped->>'status',
      nullif(v_ped->>'created_at','')::timestamptz,
      nullif(v_ped->>'approved_at','')::timestamptz,
      (nullif(v_ped->'amounts'->>'total',''))::numeric / v_norm,
      (nullif(v_ped->'amounts'->'commission'->>'total',''))::numeric
        / coalesce(nullif(v_ped->'amounts'->'commission'->>'normalizer','')::numeric, 100),
      (nullif(v_ped->'amounts'->'freight'->>'total',''))::numeric
        / coalesce(nullif(v_ped->'amounts'->'freight'->>'normalizer','')::numeric, 100),
      (nullif(v_ped->'amounts'->'discount'->>'total',''))::numeric
        / coalesce(nullif(v_ped->'amounts'->'discount'->>'normalizer','')::numeric, 100),
      coalesce(v_ped->'amounts'->>'currency', 'BRL'),
      v_ped,
      now())
    on conflict (code) do update
      set status = excluded.status, approved_at = excluded.approved_at,
          valor_total = excluded.valor_total, comissao = excluded.comissao,
          frete = excluded.frete, desconto = excluded.desconto,
          raw = excluded.raw, updated_at = now();

    delete from public.magalu_itens where code = v_ped->>'code';
    v_linha := 0;
    for v_item in
      select i.item from jsonb_array_elements(coalesce(v_ped->'deliveries','[]'::jsonb)) d(del),
                         lateral jsonb_array_elements(coalesce(d.del->'items','[]'::jsonb)) i(item)
    loop
      v_linha := v_linha + 1;
      insert into public.magalu_itens (code, linha, sku, product_name, quantity, unit_price, raw)
      values (
        v_ped->>'code', v_linha,
        coalesce(v_item->'product'->>'sku', v_item->>'sku'),
        coalesce(v_item->'product'->>'name', v_item->>'name'),
        nullif(v_item->>'quantity','')::int,
        (nullif(v_item->'unit_price'->>'value',''))::numeric
          / coalesce(nullif(v_item->'unit_price'->>'normalizer','')::numeric, 100),
        v_item);
    end loop;

    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('ok', true, 'processados', v_n,
    'total_meta', v_resp->'body'->'meta'->'page');
end $$;

-- ingestao de um mes inteiro (loop de paginas)
create or replace function public.magalu_ingest_orders(p_month text default to_char((now() at time zone 'America/Sao_Paulo')::date, 'YYYY-MM'))
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_gte date := (p_month || '-01')::date;
  v_lte date := (v_gte + interval '1 month' - interval '1 day')::date;
  v_off int := 0; v_page jsonb; v_total int := 0; v_max_pages int := 60;
begin
  loop
    v_page := public.magalu_ingest_page(v_gte, v_lte, v_off, 100);
    if coalesce((v_page->>'ok')::boolean, false) is not true then
      return jsonb_build_object('ok', false, 'ingeridos_ate_falha', v_total, 'detail', v_page);
    end if;
    v_total := v_total + coalesce((v_page->>'processados')::int, 0);
    exit when coalesce((v_page->>'processados')::int, 0) < 100;
    v_off := v_off + 100;
    v_max_pages := v_max_pages - 1;
    exit when v_max_pages <= 0;
  end loop;
  return jsonb_build_object('ok', true, 'mes', p_month, 'pedidos', v_total);
end $$;

-- ===== CARDS (mesmas reguas dos outros marketplaces) =====

create or replace function public.magalu_faturamento(p_month text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'faturamento_bruto', coalesce(sum(valor_total), 0),
    'total_pedidos',     count(*)
  )
  from public.magalu_pedidos
  where to_char(created_at at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and coalesce(status, '') <> 'cancelled';
$$;

create or replace function public.magalu_deducoes(p_month text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'comissao', coalesce(sum(comissao), 0),
    'frete',    coalesce(sum(frete), 0),
    'desconto', coalesce(sum(desconto), 0)
  )
  from public.magalu_pedidos
  where to_char(created_at at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and coalesce(status, '') <> 'cancelled';
$$;

create or replace function public.magalu_cmv(p_month text)
returns jsonb
language sql stable security definer set search_path to 'public', 'extensions'
as $$
  select jsonb_build_object(
    'cmv_total',       coalesce(sum(c.custo * i.quantity), 0),
    'itens_com_custo', count(*) filter (where c.custo is not null),
    'itens_total',     count(*)
  )
  from public.magalu_itens i
  join public.magalu_pedidos p on p.code = i.code
  left join public.ml_custo_produto c
    on c.sku = unaccent(i.sku)
   and (p.created_at at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
   and (c.vigencia_fim is null or (p.created_at at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
  where to_char(p.created_at at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and coalesce(p.status, '') <> 'cancelled';
$$;

-- cron diario: garante token e ingere o mes corrente
create or replace function public.magalu_cron_diario()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_tok jsonb; v_ing jsonb;
begin
  v_tok := public.magalu_refresh_token(false);
  if coalesce((v_tok->>'valid')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'etapa', 'token', 'detail', v_tok);
  end if;
  v_ing := public.magalu_ingest_orders();
  return jsonb_build_object('ok', coalesce((v_ing->>'ok')::boolean, false), 'ingest', v_ing);
end $$;

revoke all on function public.magalu_ingest_page(date, date, integer, integer) from anon, authenticated;
revoke all on function public.magalu_ingest_orders(text) from anon, authenticated;
revoke all on function public.magalu_cron_diario() from anon, authenticated;
revoke all on function public.magalu_faturamento(text) from anon, authenticated;
revoke all on function public.magalu_deducoes(text) from anon, authenticated;
revoke all on function public.magalu_cmv(text) from anon, authenticated;

-- crons (agendados via cron.schedule na sessao de 17/08/2026):
--   magalu-token-keepalive  */30 * * * *  select public.magalu_refresh_token(false)
--   magalu-diario           50 6 * * *    SET statement_timeout='600s'; SELECT public.magalu_cron_diario()
