-- ============================================================
-- TikTok Shop: cron diário (fecha "ontem" + reconfere 3 dias por create_time)
-- Molde ML/Shopee. Order Search → upsert idempotente → fill finance by-order.
-- Advisory lock 421982737 (token usa 736). Log em oauth_refresh_log (conta=tt_cron).
-- ============================================================

CREATE OR REPLACE FUNCTION public.tt_cron_diario()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','vault'
AS $$
DECLARE
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_ge bigint; v_lt bigint; v_body text;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_token text := ''; v_more boolean := true;
  v_order jsonb; v_item jsonb;
  v_orders int := 0; v_items int := 0; v_pages int := 0;
  v_fin jsonb;
BEGIN
  IF NOT pg_try_advisory_lock(421982737) THEN
    RETURN jsonb_build_object('skipped','already_running');
  END IF;

  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_access IS NULL THEN
    PERFORM pg_advisory_unlock(421982737);
    RETURN jsonb_build_object('error','missing_credentials');
  END IF;

  IF (SELECT expires_at FROM public.tt_oauth_state WHERE id=1) < clock_timestamp() + interval '30 minutes' THEN
    PERFORM public.tt_refresh_token(true);
    SELECT access_token INTO v_access FROM public.tt_oauth_state WHERE id=1;
  END IF;

  -- Janela: últimos 3 dias até o início de hoje BRT (fecha "ontem" + reconfere atraso), por create_time.
  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '3 days';
  v_ge := extract(epoch from v_win_start)::bigint;
  v_lt := extract(epoch from v_win_end)::bigint;
  v_body := json_build_object('create_time_ge',v_ge,'create_time_lt',v_lt)::text;

  -- FASE 1: Order Search (paginado) → upsert idempotente por order_id
  WHILE v_more LOOP
    v_resp := public._tt_post('/order/202309/orders/search',
      jsonb_build_object('page_size','100') || CASE WHEN v_token<>'' THEN jsonb_build_object('page_token',v_token) ELSE '{}'::jsonb END,
      v_body, v_app_key, v_app_secret, v_access, v_cipher);

    IF v_resp->>'error' IS NOT NULL OR (v_resp->>'code')::int <> 0 THEN
      PERFORM pg_advisory_unlock(421982737);
      RETURN jsonb_build_object('error',coalesce(v_resp->>'error','api_'||(v_resp->>'code')),'message',v_resp->>'message');
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

  -- FASE 2: enriquece finance dos não-cancelados sem repasse (captura atraso de liquidação)
  v_fin := public.tt_fill_finance(200);

  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('tt_cron', 200, true,
    'janela='||to_char(v_win_start,'YYYY-MM-DD')||'..'||to_char(v_win_end,'YYYY-MM-DD')
    ||' pedidos='||v_orders||' itens='||v_items||' pages='||v_pages
    ||' fin_done='||coalesce(v_fin->>'done','0')||' fin_fail='||coalesce(v_fin->>'fail','0')
    ||' fin_remaining='||coalesce(v_fin->>'remaining','0'));

  PERFORM pg_advisory_unlock(421982737);

  RETURN jsonb_build_object('janela_ini',v_win_start,'janela_fim',v_win_end,
    'pedidos_na_janela',v_orders,'itens',v_items,'pages',v_pages,'finance',v_fin);
END $$;

REVOKE ALL ON FUNCTION public.tt_cron_diario() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tt_cron_diario() TO service_role;

-- Cron diário: 04:00 BRT (07:00 UTC), timeout 600s. Após ML (03:00) e Shopee (03:30).
SELECT cron.schedule('tt-diario', '0 7 * * *',
  $$SET statement_timeout = '600s'; SELECT public.tt_cron_diario()$$);
