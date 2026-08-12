-- ═══════════════════════════════════════════════════════════════════════════
-- TikTok Affiliate: comissão de afiliado REAL por pedido em D+0 (12/08/2026)
-- Contexto: o app antigo "Hub Financeiro Essenza" (ISV/Contabilidade, app_key
-- 6kgr85hkbgv3q) não tinha o scope de afiliado no pacote. Criado app novo
-- "Hub Financeiro Essenza Inhouse" (categoria Desenvolvedor inhouse do vendedor,
-- app_key 6kunfi6tu9pf2, service_id 7672994338307409671, mesma callback) com
-- 4 scopes: seller.order.info, seller.finance.info, seller.authorization.info,
-- seller.affiliate_collaboration.read. Vault (tt_app_key/tt_app_secret)
-- atualizado e loja re-autorizada em 12/08/2026.
-- Endpoint: POST /affiliate_seller/202410/orders/search — orders[].skus[] com
-- estimated/actual_paid_commission (criador), estimated/actual_paid_partner_
-- commission (TAP), commission_rate em bps x100 (600=6%), settlement_status.
-- estimated_paid_shop_ads_commission NÃO é somado (é ads; vem no settlement).
-- ═══════════════════════════════════════════════════════════════════════════

-- Runner genérico da Affiliate Seller API (validação de schema / debug).
create or replace function public.tt_aff_search(p_body jsonb default '{}'::jsonb, p_extra jsonb default jsonb_build_object('page_size','20'))
returns jsonb
language plpgsql security definer
set search_path to 'public','extensions','vault'
as $function$
declare v_app_key text; v_app_secret text; v_access text; v_cipher text;
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name='tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name='tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher from public.tt_oauth_state where id=1;
  if v_app_key is null or v_access is null then return jsonb_build_object('error','missing_credentials'); end if;
  if (select expires_at from public.tt_oauth_state where id=1) < clock_timestamp() + interval '15 minutes' then
    perform public.tt_refresh_token(true);
    select access_token into v_access from public.tt_oauth_state where id=1;
  end if;
  return public._tt_post('/affiliate_seller/202410/orders/search', p_extra, p_body::text,
                         v_app_key, v_app_secret, v_access, v_cipher);
end $function$;

-- Comissão de afiliado real por pedido.
-- Regras:
--  - aff_commission = criador (paid_commission) + parceiro TAP (paid_partner_commission);
--    usa actual_* quando liquidado, senão estimated_*.
--  - Pagina do mais recente para trás; para quando sai da janela p_days.
--  - Pedidos na janela SEM registro de afiliado (>24h de idade) recebem aff_filled=true com 0:
--    dentro da janela coberta, ausência = venda orgânica; <24h aguarda (atribuição pode atrasar).
create or replace function public.tt_fill_affiliate(p_days integer default 14, p_max_pages integer default 30)
returns jsonb
language plpgsql security definer
set search_path to 'public','extensions','vault'
set statement_timeout to '300s'
as $function$
declare
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_resp jsonb; v_token text := ''; v_more boolean := true;
  v_order jsonb; v_sku jsonb; v_pages int := 0;
  v_cutoff bigint := extract(epoch from now() - make_interval(days => p_days))::bigint;
  v_oldest bigint; v_comm numeric;
  v_matched int := 0; v_zerados int := 0;
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name='tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name='tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher from public.tt_oauth_state where id=1;
  if v_app_key is null or v_access is null then return jsonb_build_object('error','missing_credentials'); end if;
  if (select expires_at from public.tt_oauth_state where id=1) < clock_timestamp() + interval '15 minutes' then
    perform public.tt_refresh_token(true);
    select access_token into v_access from public.tt_oauth_state where id=1;
  end if;

  while v_more and v_pages < p_max_pages loop
    v_resp := public._tt_post('/affiliate_seller/202410/orders/search',
      jsonb_build_object('page_size','50')
        || case when v_token <> '' then jsonb_build_object('page_token', v_token) else '{}'::jsonb end,
      '{}', v_app_key, v_app_secret, v_access, v_cipher);
    if v_resp->>'error' is not null or coalesce((v_resp->>'code')::int, -1) <> 0 then
      return jsonb_build_object('error', coalesce(v_resp->>'error','api_'||(v_resp->>'code')),
                                'message', v_resp->>'message', 'pages_ok', v_pages);
    end if;
    v_pages := v_pages + 1;
    v_oldest := null;

    for v_order in select value from jsonb_array_elements(coalesce(v_resp->'data'->'orders','[]'::jsonb)) loop
      v_oldest := least(coalesce(v_oldest, (v_order->>'create_time')::bigint), (v_order->>'create_time')::bigint);
      v_comm := 0;
      for v_sku in select value from jsonb_array_elements(coalesce(v_order->'skus','[]'::jsonb)) loop
        v_comm := v_comm
          + coalesce(nullif(v_sku->'actual_paid_commission'->>'amount','')::numeric,
                     nullif(v_sku->'estimated_paid_commission'->>'amount','')::numeric, 0)
          + coalesce(nullif(v_sku->'actual_paid_partner_commission'->>'amount','')::numeric,
                     nullif(v_sku->'estimated_paid_partner_commission'->>'amount','')::numeric, 0);
      end loop;
      update public.tt_pedidos
         set aff_commission = v_comm, aff_filled = true
       where order_id = v_order->>'id';
      if found then v_matched := v_matched + 1; end if;
    end loop;

    v_token := coalesce(v_resp->'data'->>'next_page_token','');
    v_more := v_token <> '' and (v_oldest is null or v_oldest >= v_cutoff);
  end loop;

  -- Janela coberta e pedido não apareceu na busca de afiliados => venda orgânica (afiliado 0).
  update public.tt_pedidos
     set aff_commission = 0, aff_filled = true
   where not aff_filled
     and create_time >= now() - make_interval(days => p_days)
     and create_time < now() - interval '24 hours'
     and order_status not in ('CANCELLED','UNPAID');
  get diagnostics v_zerados = row_count;

  return jsonb_build_object('pages', v_pages, 'com_afiliado', v_matched, 'organicos_zerados', v_zerados);
end $function$;

-- FASE 3 no cron diário: comissão de afiliado real por pedido (tt_fill_affiliate).
create or replace function public.tt_cron_diario()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
DECLARE
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_ge bigint; v_lt bigint; v_body text;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_token text := ''; v_more boolean := true;
  v_order jsonb; v_item jsonb;
  v_orders int := 0; v_items int := 0; v_pages int := 0;
  v_fin jsonb; v_aff jsonb;
  -- erro capturado por fase (NULL = fase ok)
  v_err_pedidos text; v_err_fin text; v_err_aff text; v_erros text; v_ok boolean;
BEGIN
  IF NOT pg_try_advisory_lock(421982737) THEN
    RETURN jsonb_build_object('skipped','already_running');
  END IF;
  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_access IS NULL THEN
    INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
    VALUES ('tt_cron', NULL, false, 'missing_credentials');
    PERFORM pg_advisory_unlock(421982737);
    RETURN jsonb_build_object('error','missing_credentials');
  END IF;
  -- Refresh preventivo do token: se falhar, segue com o token atual
  BEGIN
    IF (SELECT expires_at FROM public.tt_oauth_state WHERE id=1) < clock_timestamp() + interval '30 minutes' THEN
      PERFORM public.tt_refresh_token(true);
      SELECT access_token INTO v_access FROM public.tt_oauth_state WHERE id=1;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '7 days';  -- 3->7: alinha com ML/Shopee (janela curta cria vao)
  v_ge := extract(epoch from v_win_start)::bigint;
  v_lt := extract(epoch from v_win_end)::bigint;
  v_body := json_build_object('create_time_ge',v_ge,'create_time_lt',v_lt)::text;

  -- FASE 1: pedidos da janela (erro de API vira exceção capturada e logada,
  -- não RETURN precoce sem log)
  BEGIN
    WHILE v_more LOOP
      v_resp := public._tt_post('/order/202309/orders/search',
        jsonb_build_object('page_size','100') || CASE WHEN v_token<>'' THEN jsonb_build_object('page_token',v_token) ELSE '{}'::jsonb END,
        v_body, v_app_key, v_app_secret, v_access, v_cipher);
      IF v_resp->>'error' IS NOT NULL OR (v_resp->>'code')::int <> 0 THEN
        RAISE EXCEPTION 'orders/search: % %',
          coalesce(v_resp->>'error','api_'||(v_resp->>'code')), coalesce(v_resp->>'message','');
      END IF;
      v_pages := v_pages + 1;
      FOR v_order IN SELECT value FROM jsonb_array_elements(coalesce(v_resp->'data'->'orders','[]'::jsonb)) LOOP
        INSERT INTO public.tt_pedidos (order_id, create_time, order_status, currency, payment_total)
        VALUES (v_order->>'id', to_timestamp((v_order->>'create_time')::bigint), v_order->>'status',
                v_order->'payment'->>'currency', nullif(v_order->'payment'->>'total_amount','')::numeric)
        ON CONFLICT (order_id) DO UPDATE
          SET order_status=excluded.order_status, payment_total=excluded.payment_total;
        v_orders := v_orders + 1;
        FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_order->'line_items','[]'::jsonb)) LOOP
          INSERT INTO public.tt_itens (order_id, line_item_id, seller_sku, sku_id, product_name, line_status, sale_price, original_price, seller_discount, quantity)
          VALUES (v_order->>'id', v_item->>'id', v_item->>'seller_sku', v_item->>'sku_id', v_item->>'product_name',
                  v_item->>'display_status', nullif(v_item->>'sale_price','')::numeric,
                  nullif(v_item->>'original_price','')::numeric, nullif(v_item->>'seller_discount','')::numeric, 1)
          ON CONFLICT (order_id, line_item_id) DO UPDATE SET line_status=excluded.line_status;
          v_items := v_items + 1;
        END LOOP;
      END LOOP;
      v_token := coalesce(v_resp->'data'->>'next_page_token','');
      v_more := v_token <> '';
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    v_err_pedidos := SQLERRM;
  END;

  -- FASE 2: finance dos pedidos pendentes (fila re-tentada todo dia)
  BEGIN
    v_fin := public.tt_fill_finance(200);
  EXCEPTION WHEN OTHERS THEN
    v_err_fin := SQLERRM;
  END;

  -- FASE 3: comissão de afiliado real por pedido (D+0; re-varre 14 dias p/ pegar actual_* pós-liquidação)
  BEGIN
    v_aff := public.tt_fill_affiliate(14);
    IF v_aff->>'error' IS NOT NULL THEN v_err_aff := v_aff->>'error'; END IF;
  EXCEPTION WHEN OTHERS THEN
    v_err_aff := SQLERRM;
  END;

  -- Log SEMPRE (sucesso ou falha) — concat_ws descarta os NULL das fases ok.
  v_erros := concat_ws(' | ', 'pedidos: ' || v_err_pedidos, 'finance: ' || v_err_fin, 'afiliado: ' || v_err_aff);
  v_ok := (v_erros IS NULL OR v_erros = '')
          AND coalesce((v_fin->>'fail')::int, 0) = 0 AND (v_fin->>'error') IS NULL;
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('tt_cron', CASE WHEN v_ok THEN 200 END, v_ok,
    case when v_erros is not null and v_erros <> '' then 'ERROS: '||v_erros
         when (v_fin->>'error') is not null then 'FALHA no finance: '||(v_fin->>'error')
         when coalesce((v_fin->>'fail')::int,0) > 0 then (v_fin->>'fail')||' pedidos com ERRO real no finance'
         else 'ok' end
    ||' | janela='||to_char(v_win_start,'YYYY-MM-DD')||'..'||to_char(v_win_end,'YYYY-MM-DD')
    ||' pedidos='||v_orders||' itens='||v_items||' pages='||v_pages
    ||' fin_done='||coalesce(v_fin->>'done','0')
    ||' aguardando_liquidar='||coalesce(v_fin->>'aguardando_liquidar','0')
    ||' throttled_429='||coalesce(v_fin->>'throttled_429','0')
    ||' fin_fail='||coalesce(v_fin->>'fail','0')
    ||' fin_remaining='||coalesce(v_fin->>'remaining','0')
    ||' aff_com='||coalesce(v_aff->>'com_afiliado','0')
    ||' aff_organicos='||coalesce(v_aff->>'organicos_zerados','0'));
  PERFORM pg_advisory_unlock(421982737);
  RETURN jsonb_build_object('janela_ini',v_win_start,'janela_fim',v_win_end,
    'pedidos_na_janela',v_orders,'itens',v_items,'pages',v_pages,'finance',v_fin,'afiliado',v_aff,
    'erros', CASE WHEN v_erros IS NULL OR v_erros = '' THEN NULL ELSE v_erros END);
END $function$;
