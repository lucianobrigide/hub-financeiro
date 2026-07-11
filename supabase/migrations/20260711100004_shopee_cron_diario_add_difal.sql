-- Adiciona FASE 5 (DIFAL) ao orquestrador diário da Shopee. Varre a carteira numa janela
-- trailing de ~16 dias (a busca é pesada: milhares de transações; DIFAL posta em dias do
-- pedido). shopee_fill_difal chunka internamente em janelas de 15 dias (cap da API).
-- NÃO agenda nada novo: o job shopee-diario (03:30 BRT) já existe, só ganhou o passo.
CREATE OR REPLACE FUNCTION public.shopee_cron_diario()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_more boolean; v_cursor text;
  v_page_sns text[]; v_new_sns text[]; v_all_new text[] := '{}';
  v_batch text[]; v_detail jsonb; v_order jsonb; v_item jsonb;
  v_sn text; v_income jsonb; v_i int;
  v_listed int := 0; v_inserted int := 0;
  v_escrow_done int := 0; v_escrow_fail int := 0; v_escrow_remaining int := 0;
  v_today date;
  v_ads_cur jsonb; v_ads_prev jsonb; v_ads_dias int := 0; v_ads_expense numeric := 0;
  v_difal jsonb; v_difal_cnt int := 0;
BEGIN
  IF NOT pg_try_advisory_lock(421982738) THEN
    RETURN jsonb_build_object('skipped', 'already_running');
  END IF;

  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id FROM shopee_oauth_state WHERE id = 1;

  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    PERFORM pg_advisory_unlock(421982738);
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;

  IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1)
     < clock_timestamp() + interval '30 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
  END IF;

  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '7 days';

  -- FASE 1: Listar COMPLETED na janela
  v_more := true; v_cursor := '';
  WHILE v_more LOOP
    v_resp := _sp_api_get('/api/v2/order/get_order_list',
      'time_range_field=create_time'
        || '&time_from=' || extract(epoch from v_win_start)::bigint
        || '&time_to='   || extract(epoch from v_win_end)::bigint
        || '&page_size=100&order_status=COMPLETED'
        || CASE WHEN v_cursor <> '' THEN '&cursor=' || v_cursor ELSE '' END,
      v_pid, v_pkey, v_access, v_shop_id);
    IF v_resp->>'error' IS NOT NULL AND v_resp->>'error' <> '' THEN
      PERFORM pg_advisory_unlock(421982738);
      RETURN jsonb_build_object('error', v_resp->>'error', 'listed', v_listed);
    END IF;
    IF v_resp->'response'->'order_list' IS NOT NULL THEN
      SELECT array_agg(el->>'order_sn') INTO v_page_sns
      FROM jsonb_array_elements(v_resp->'response'->'order_list') AS el;
      IF v_page_sns IS NOT NULL THEN
        v_listed := v_listed + array_length(v_page_sns, 1);
        SELECT array_agg(sn) INTO v_new_sns FROM unnest(v_page_sns) AS sn
        WHERE NOT EXISTS (SELECT 1 FROM shopee_pedidos sp WHERE sp.order_sn = sn);
        IF v_new_sns IS NOT NULL THEN v_all_new := v_all_new || v_new_sns; END IF;
      END IF;
    END IF;
    v_more := COALESCE((v_resp->'response'->>'more')::boolean, false);
    v_cursor := COALESCE(v_resp->'response'->>'next_cursor', '');
  END LOOP;

  -- FASE 2: Detail dos novos (batches de 50)
  IF array_length(v_all_new, 1) IS NOT NULL AND array_length(v_all_new, 1) > 0 THEN
    v_i := 1;
    WHILE v_i <= array_length(v_all_new, 1) LOOP
      v_batch := v_all_new[v_i : LEAST(v_i + 49, array_length(v_all_new, 1))];
      v_detail := _sp_api_get('/api/v2/order/get_order_detail',
        'order_sn_list=' || array_to_string(v_batch, ',') || '&response_optional_fields=item_list',
        v_pid, v_pkey, v_access, v_shop_id);
      IF v_detail->'response'->'order_list' IS NOT NULL THEN
        FOR v_order IN SELECT value FROM jsonb_array_elements(v_detail->'response'->'order_list') LOOP
          INSERT INTO shopee_pedidos (order_sn, create_time, pay_time, order_status)
          VALUES (v_order->>'order_sn', to_timestamp((v_order->>'create_time')::bigint),
            CASE WHEN (v_order->>'pay_time')::bigint > 0 THEN to_timestamp((v_order->>'pay_time')::bigint) END,
            v_order->>'order_status')
          ON CONFLICT (order_sn) DO NOTHING;
          FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_order->'item_list', '[]'::jsonb)) LOOP
            INSERT INTO shopee_itens (order_sn, item_id, model_id, item_sku, model_sku, item_name, quantity, unit_price, original_price)
            VALUES (v_order->>'order_sn', (v_item->>'item_id')::bigint, COALESCE((v_item->>'model_id')::bigint, 0),
              v_item->>'item_sku', v_item->>'model_sku', v_item->>'item_name',
              COALESCE((v_item->>'model_quantity_purchased')::int, 1),
              (v_item->>'model_discounted_price')::numeric, (v_item->>'model_original_price')::numeric)
            ON CONFLICT (order_sn, item_id, model_id) DO NOTHING;
          END LOOP;
          v_inserted := v_inserted + 1;
        END LOOP;
      END IF;
      v_i := v_i + 50;
    END LOOP;
  END IF;

  -- FASE 3: Escrow + AMS (limit 200 por run)
  FOR v_sn IN SELECT order_sn FROM shopee_pedidos WHERE selling_price IS NULL ORDER BY create_time LIMIT 200 LOOP
    v_resp := _sp_api_get('/api/v2/payment/get_escrow_detail', 'order_sn=' || v_sn, v_pid, v_pkey, v_access, v_shop_id);
    v_income := v_resp->'response'->'order_income';
    IF v_income IS NOT NULL THEN
      UPDATE shopee_pedidos SET
        selling_price=(v_income->>'cost_of_goods_sold')::numeric, net_commission=(v_income->>'net_commission_fee')::numeric,
        net_service_fee=(v_income->>'net_service_fee')::numeric, shipping_fee=(v_income->>'actual_shipping_fee')::numeric,
        escrow_amount=(v_income->>'escrow_amount')::numeric, escrow_adjusted=(v_income->>'escrow_amount_after_adjustment')::numeric,
        buyer_total=(v_income->>'buyer_total_amount')::numeric, ams_commission=COALESCE((v_income->>'order_ams_commission_fee')::numeric, 0)
      WHERE order_sn = v_sn;
      v_escrow_done := v_escrow_done + 1;
    ELSE v_escrow_fail := v_escrow_fail + 1;
    END IF;
  END LOOP;
  SELECT COUNT(*) INTO v_escrow_remaining FROM shopee_pedidos WHERE selling_price IS NULL;

  -- FASE 4: ADS (gasto CPC diário) — mês atual MTD + mês anterior (API cap 1 mês)
  v_today := (clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date;
  v_ads_cur  := shopee_fill_ads(date_trunc('month', v_today)::date, v_today);
  v_ads_prev := shopee_fill_ads(date_trunc('month', v_today - interval '1 month')::date, (date_trunc('month', v_today)::date - 1));
  v_ads_dias    := COALESCE((v_ads_cur->>'dias')::int, 0) + COALESCE((v_ads_prev->>'dias')::int, 0);
  v_ads_expense := COALESCE((v_ads_cur->>'expense_total')::numeric, 0) + COALESCE((v_ads_prev->>'expense_total')::numeric, 0);

  -- FASE 5: DIFAL (ICMS interestadual da carteira) — janela trailing ~16 dias (fill chunka em 15d)
  v_difal := shopee_fill_difal((v_today - interval '16 days')::timestamptz, (v_today + interval '1 day')::timestamptz);
  v_difal_cnt := COALESCE((v_difal->>'difal_cobrancas')::int, 0);

  INSERT INTO oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_cron', 200, true,
    'listed=' || v_listed || ' new=' || v_inserted
    || ' escrow=' || v_escrow_done || ' escrow_fail=' || v_escrow_fail || ' escrow_pending=' || v_escrow_remaining
    || ' ads_dias=' || v_ads_dias || ' ads_expense=' || round(v_ads_expense, 2)
    || ' difal_cobrancas=' || v_difal_cnt);

  PERFORM pg_advisory_unlock(421982738);

  RETURN jsonb_build_object(
    'listed', v_listed, 'new_orders', v_inserted,
    'escrow_done', v_escrow_done, 'escrow_fail', v_escrow_fail, 'escrow_pending', v_escrow_remaining,
    'ads_dias', v_ads_dias, 'ads_expense', round(v_ads_expense, 2),
    'difal_cobrancas', v_difal_cnt);
END $$;

REVOKE ALL ON FUNCTION public.shopee_cron_diario() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopee_cron_diario() TO service_role;
