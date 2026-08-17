-- Fix: na resposta real do /seller/v1/orders o SKU/nome do item vivem em items[].info
-- (a doc mostra "product", a API devolve "info"). Sem isso, magalu_itens fica com sku NULL
-- e o CMV nunca casa com ml_custo_produto. Validado 17/08/2026: apos o fix + reingestao,
-- magalu_cmv ago/2026 = R$ 127,60 (1 de 1 itens com custo, SKU MARPAL9PRETO ja no de-para).

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
        coalesce(v_item->'info'->>'sku', v_item->'product'->>'sku', v_item->>'sku'),
        coalesce(v_item->'info'->>'name', v_item->'product'->>'name', v_item->>'name'),
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
