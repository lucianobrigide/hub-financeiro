-- Ingestão SHEIN (fase 100% — pedidos + itens + deduções do pedido).
-- Fonte: /open-api/order/order-list (POST, janela MÁX 48h, queryType=1) +
--        /open-api/order/order-detail (POST, até 30 orderNos por chamada).
-- Réguas (doc oficial, apidoc 3001915, lida 07/08/2026):
--   · TODOS os horários da API são fuso de PEQUIM (UTC+8) — janelas formatadas
--     em Asia/Shanghai; timestamps do detail vêm com offset (+0800), parse direto.
--   · Cada UNIDADE vendida é um goodsId próprio (qty=1 por linha de item).
--   · orderStatus: 1 pendente / 2 aguard. envio / 3 aguard. envio SHEIN / 4 enviado /
--     5 assinado / 6 reembolso / 7 aguard. retirada / 8 danificado / 9 recusado.
--   · Deduções REAIS por pedido (autooperação): totalCommission,
--     totalPerformanceServiceCharge, storeDiscountTotalPrice, promotionDiscountTotalPrice.
--     estimatedGrossIncome = produto − cupons − promos − taxa serviço − comissão.
-- Régua do card (MVP-100%, a conciliar com settlement depois):
--   bruta = Σ productTotalPrice com status NOT IN (6,8,9); competência payment_time BRT.
-- Tabelas recriadas (estavam vazias, shape do MVP era provisório).

drop table if exists public.shein_itens;
drop table if exists public.shein_pedidos;

create table public.shein_pedidos (
  order_no          text primary key,
  order_status      int,
  order_time        timestamptz,
  payment_time      timestamptz,
  update_time       timestamptz,
  sales_site        text,
  currency          text,
  produto_total     numeric(14,2),
  desconto_loja     numeric(14,2),
  desconto_promo    numeric(14,2),
  comissao          numeric(14,2),
  taxa_servico      numeric(14,2),
  frete_comprador   numeric(14,2),
  receita_estimada  numeric(14,2),
  invoice_status    int,
  raw               jsonb,
  inserted_at       timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.shein_pedidos is
  'Pedidos SHEIN via order-detail (autooperacao). Valores do PEDIDO (pre-settlement): comissao/taxa/cupons reais da API. Competencia = payment_time (BRT nos RPCs). Horarios da API em UTC+8, gravados como timestamptz.';
create index shein_pedidos_payment_time_idx on public.shein_pedidos (payment_time);
alter table public.shein_pedidos enable row level security;

create table public.shein_itens (
  order_no           text not null,
  goods_id           bigint not null,
  seller_sku         text,
  sku_code           text,
  goods_title        text,
  status             int,
  preco              numeric(14,2),
  preco_com_desconto numeric(14,2),
  cupom              numeric(14,2),
  promo              numeric(14,2),
  comissao           numeric(14,2),
  comissao_pct       numeric(8,4),
  taxa_servico       numeric(14,2),
  receita_estimada   numeric(14,2),
  primary key (order_no, goods_id)
);
comment on table public.shein_itens is
  'Itens SHEIN: cada goodsId = UMA unidade (qty=1 por linha, regra da API). seller_sku = nosso SKU (join com ml_custo_produto).';
alter table public.shein_itens enable row level security;

-- Chamada assinada à API SHEIN (POST json). Retorna {http_status, body(jsonb|null)}.
create or replace function public.shein_api_call(p_path text, p_body jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_h jsonb; v_resp extensions.http_response; v_body jsonb;
begin
  v_h := public.shein_signed_headers(p_path);
  if v_h ? 'error' then
    return jsonb_build_object('http_status', null, 'body', v_h);
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

  select * into v_resp from extensions.http((
    'POST',
    v_h->>'full_url',
    array[
      extensions.http_header('x-lt-openKeyId', v_h->'headers'->>'x-lt-openKeyId'),
      extensions.http_header('x-lt-timestamp', v_h->'headers'->>'x-lt-timestamp'),
      extensions.http_header('x-lt-signature', v_h->'headers'->>'x-lt-signature')
    ],
    'application/json',
    p_body::text
  )::extensions.http_request);

  v_body := case when left(coalesce(v_resp.content, ''), 1) in ('{', '[')
                 then v_resp.content::jsonb else null end;
  return jsonb_build_object('http_status', v_resp.status, 'body', v_body);
end $$;

-- Upsert de UM pedido a partir do elemento info[] do order-detail.
create or replace function public.shein_upsert_pedido(p jsonb)
returns int language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_no text := p->>'orderNo';
  g jsonb; v_itens int := 0;
begin
  if v_no is null then return 0; end if;

  insert into public.shein_pedidos as sp (
    order_no, order_status, order_time, payment_time, update_time,
    sales_site, currency, produto_total, desconto_loja, desconto_promo,
    comissao, taxa_servico, frete_comprador, receita_estimada, invoice_status,
    raw, updated_at
  ) values (
    v_no,
    (p->>'orderStatus')::int,
    nullif(p->>'orderTime', '')::timestamptz,
    nullif(p->>'paymentTime', '')::timestamptz,
    nullif(p->>'orderMsgUpdateTime', '')::timestamptz,
    p->>'salesSite',
    p->>'orderCurrency',
    (p->>'productTotalPrice')::numeric,
    coalesce((p->>'storeDiscountTotalPrice')::numeric, 0),
    coalesce((p->>'promotionDiscountTotalPrice')::numeric, 0),
    coalesce((p->>'totalCommission')::numeric, 0),
    coalesce((p->>'totalPerformanceServiceCharge')::numeric, 0),
    nullif(p->>'sellerShippingFee', '')::numeric,
    (p->>'estimatedGrossIncome')::numeric,
    (p->>'invoiceStatus')::int,
    p, now()
  )
  on conflict (order_no) do update set
    order_status     = excluded.order_status,
    order_time       = excluded.order_time,
    payment_time     = excluded.payment_time,
    update_time      = excluded.update_time,
    sales_site       = excluded.sales_site,
    currency         = excluded.currency,
    produto_total    = excluded.produto_total,
    desconto_loja    = excluded.desconto_loja,
    desconto_promo   = excluded.desconto_promo,
    comissao         = excluded.comissao,
    taxa_servico     = excluded.taxa_servico,
    frete_comprador  = excluded.frete_comprador,
    receita_estimada = excluded.receita_estimada,
    invoice_status   = excluded.invoice_status,
    raw              = excluded.raw,
    updated_at       = now();

  delete from public.shein_itens where order_no = v_no;
  for g in select * from jsonb_array_elements(coalesce(p->'orderGoodsInfoList', '[]'::jsonb))
  loop
    insert into public.shein_itens (
      order_no, goods_id, seller_sku, sku_code, goods_title, status,
      preco, preco_com_desconto, cupom, promo,
      comissao, comissao_pct, taxa_servico, receita_estimada
    ) values (
      v_no,
      (g->>'goodsId')::bigint,
      g->>'sellerSku',
      g->>'skuCode',
      g->>'goodsTitle',
      (g->>'newGoodsStatus')::int,
      (g->>'sellerCurrencyPrice')::numeric,
      (g->>'sellerCurrencyDiscountPrice')::numeric,
      coalesce((g->>'orderCurrencyStoreCouponPrice')::numeric, 0),
      coalesce((g->>'orderCurrencyPromotionPrice')::numeric, 0),
      coalesce((g->>'commission')::numeric, 0),
      (g->>'commissionRate')::numeric,
      coalesce((g->>'performanceServiceCharge')::numeric, 0),
      (g->>'estimatedIncome')::numeric
    )
    on conflict (order_no, goods_id) do nothing;
    v_itens := v_itens + 1;
  end loop;

  return v_itens;
end $$;

-- Ingestão por janela: varre [p_de, p_ate) em janelas de 47h (cap da API: 48h),
-- lista → detalha em lotes de 30 → upsert. Cada janela roda em subtransação
-- (falha de uma janela não descarta as demais — padrão fases resilientes).
create or replace function public.shein_fill_pedidos(p_de timestamptz, p_ate timestamptz)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_ini timestamptz := p_de;
  v_fim timestamptz;
  v_fmt_ini text; v_fmt_fim text;
  v_resp jsonb; v_body jsonb; v_list jsonb;
  v_page int; v_count int;
  v_nos text[]; v_batch text[];
  v_ped int := 0; v_it int := 0; v_jan int := 0; v_err int := 0;
  v_t0 timestamptz := clock_timestamp();
  i int; e jsonb;
begin
  while v_ini < p_ate loop
    v_fim := least(v_ini + interval '47 hours', p_ate);
    v_jan := v_jan + 1;
    begin
      -- horários da API em fuso de Pequim
      v_fmt_ini := to_char(v_ini at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS');
      v_fmt_fim := to_char(v_fim at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS');

      v_nos := '{}'; v_page := 1;
      loop
        v_resp := public.shein_api_call('/open-api/order/order-list', jsonb_build_object(
          'queryType', 1, 'startTime', v_fmt_ini, 'endTime', v_fmt_fim,
          'page', v_page, 'pageSize', 30));
        v_body := v_resp->'body';
        if (v_resp->>'http_status')::int is distinct from 200 or (v_body->>'code') <> '0' then
          raise exception 'order-list falhou (janela % → %): HTTP % | %',
            v_fmt_ini, v_fmt_fim, v_resp->>'http_status', left(coalesce(v_body::text, 'sem corpo'), 300);
        end if;
        v_list := v_body->'info'->'orderList';
        exit when v_list is null or jsonb_array_length(v_list) = 0;
        select array_agg(x->>'orderNo') || v_nos from jsonb_array_elements(v_list) x into v_nos;
        v_count := coalesce((v_body->'info'->>'count')::int, 0);
        exit when v_page * 30 >= v_count or v_page >= 40;
        v_page := v_page + 1;
      end loop;

      -- detalhe em lotes de 30
      i := 1;
      while v_nos is not null and i <= coalesce(array_length(v_nos, 1), 0) loop
        v_batch := v_nos[i : least(i + 29, array_length(v_nos, 1))];
        v_resp := public.shein_api_call('/open-api/order/order-detail',
                                        jsonb_build_object('orderNoList', to_jsonb(v_batch)));
        v_body := v_resp->'body';
        if (v_resp->>'http_status')::int is distinct from 200 or (v_body->>'code') <> '0' then
          raise exception 'order-detail falhou (lote %..%): HTTP % | %',
            i, i + 29, v_resp->>'http_status', left(coalesce(v_body::text, 'sem corpo'), 300);
        end if;
        for e in select * from jsonb_array_elements(coalesce(v_body->'info', '[]'::jsonb))
        loop
          v_it := v_it + public.shein_upsert_pedido(e);
          v_ped := v_ped + 1;
        end loop;
        i := i + 30;
      end loop;
    exception when others then
      v_err := v_err + 1;
      insert into public.ml_cron_log (job, dia_alvo, sucesso, mensagem)
      values ('shein_fill', (v_ini at time zone 'America/Sao_Paulo')::date, false,
              'janela ' || v_fmt_ini || '→' || v_fmt_fim || ': ' || SQLERRM);
    end;
    v_ini := v_fim;
  end loop;

  insert into public.ml_cron_log (job, dia_alvo, sucesso, pedidos, duracao_ms, mensagem)
  values ('shein_fill', (p_ate at time zone 'America/Sao_Paulo')::date, v_err = 0, v_ped,
          (extract(epoch from clock_timestamp() - v_t0) * 1000)::int,
          format('janelas=%s pedidos=%s itens=%s erros=%s (%s → %s)', v_jan, v_ped, v_it, v_err,
                 to_char(p_de at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                 to_char(p_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')));

  return jsonb_build_object('janelas', v_jan, 'pedidos', v_ped, 'itens', v_it, 'erros', v_err);
end $$;

-- Cron diário: re-sincroniza os últimos 3 dias (pega mudanças de status/devoluções).
create or replace function public.shein_cron_diario()
returns jsonb language sql security definer
set search_path to 'public'
as $$ select public.shein_fill_pedidos(now() - interval '3 days', now()); $$;

-- ── RPCs do card (substituem as versões MVP) ──
-- Competência: payment_time (fallback order_time) em BRT.
-- Régua bruta: status NOT IN (6,8,9); devoluções = status IN (6,8,9).
drop function if exists public.shein_faturamento(text);
create or replace function public.shein_faturamento(p_month text)
returns jsonb language sql stable security definer
set search_path to 'public'
as $$
  with base as (
    select *, coalesce(payment_time, order_time) as competencia
    from public.shein_pedidos
    where to_char(coalesce(payment_time, order_time) at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
  )
  select jsonb_build_object(
    'faturamento_bruto', coalesce(sum(produto_total) filter (where order_status not in (6,8,9)), 0),
    'cancel_devolucoes', coalesce(sum(produto_total) filter (where order_status in (6,8,9)), 0),
    'total_pedidos',     count(*) filter (where order_status not in (6,8,9))
  ) from base;
$$;

create or replace function public.shein_deducoes(p_month text)
returns jsonb language sql stable security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'comissao',      coalesce(sum(comissao), 0),
    'taxa_servico',  coalesce(sum(taxa_servico), 0),
    'cupons_promos', coalesce(sum(desconto_loja + desconto_promo), 0)
  )
  from public.shein_pedidos
  where to_char(coalesce(payment_time, order_time) at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and order_status not in (6,8,9);
$$;

-- CMV: cada linha de item = 1 unidade; join seller_sku × ml_custo_produto com
-- vigência ancorada na competência do pedido (payment_time BRT) — padrão sp_cmv.
drop function if exists public.shein_cmv(text);
create or replace function public.shein_cmv(p_month text)
returns jsonb language sql stable security definer
set search_path to 'public', 'extensions'
as $$
  select jsonb_build_object(
    'cmv_total',       coalesce(sum(c.custo), 0),
    'itens_com_custo', count(*) filter (where c.custo is not null),
    'itens_total',     count(*)
  )
  from public.shein_itens i
  join public.shein_pedidos p on p.order_no = i.order_no
  left join public.ml_custo_produto c
    on c.sku = unaccent(i.seller_sku)
   and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
   and (c.vigencia_fim is null
        or (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
  where to_char(coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and p.order_status not in (6,8,9);
$$;

-- Crons: diário 03:50 BRT (06:50 UTC) re-sync 3 dias; semanal dom 05:35 BRT re-sync 30 dias.
select cron.schedule('shein-diario', '50 6 * * *',
  $cmd$SET statement_timeout='600s'; SELECT public.shein_cron_diario()$cmd$);
select cron.schedule('shein-semanal', '35 8 * * 0',
  $cmd$SET statement_timeout='900s'; SELECT public.shein_fill_pedidos(now() - interval '30 days', now())$cmd$);

-- Permissões: só service_role
revoke all on function public.shein_api_call(text, jsonb)                    from public, anon, authenticated;
revoke all on function public.shein_upsert_pedido(jsonb)                     from public, anon, authenticated;
revoke all on function public.shein_fill_pedidos(timestamptz, timestamptz)   from public, anon, authenticated;
revoke all on function public.shein_cron_diario()                            from public, anon, authenticated;
revoke all on function public.shein_faturamento(text)                        from public, anon, authenticated;
revoke all on function public.shein_deducoes(text)                           from public, anon, authenticated;
revoke all on function public.shein_cmv(text)                                from public, anon, authenticated;
grant execute on function public.shein_api_call(text, jsonb)                  to service_role;
grant execute on function public.shein_upsert_pedido(jsonb)                   to service_role;
grant execute on function public.shein_fill_pedidos(timestamptz, timestamptz) to service_role;
grant execute on function public.shein_cron_diario()                          to service_role;
grant execute on function public.shein_faturamento(text)                      to service_role;
grant execute on function public.shein_deducoes(text)                         to service_role;
grant execute on function public.shein_cmv(text)                              to service_role;
