-- ============================================================
-- Shopee: AMS (afiliados), cron diário, funções auxiliares
-- Complementa 20260709210001_shopee_ingest.sql
-- ============================================================

-- 1. Coluna ams_commission (order_ams_commission_fee do escrow)
ALTER TABLE public.shopee_pedidos
  ADD COLUMN IF NOT EXISTS ams_commission numeric;

-- 2. shopee_fill_escrow: SKIP LOCKED para workers paralelos
CREATE OR REPLACE FUNCTION public.shopee_fill_escrow(p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_sn     text;
  v_resp   jsonb;
  v_income jsonb;
  v_done   int := 0;
  v_failed int := 0;
  v_remaining int;
BEGIN
  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id
    FROM shopee_oauth_state WHERE id = 1;

  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;

  IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1)
     < clock_timestamp() + interval '10 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
  END IF;

  FOR v_sn IN
    SELECT order_sn FROM shopee_pedidos
    WHERE selling_price IS NULL
    ORDER BY create_time
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_resp := _sp_api_get(
      '/api/v2/payment/get_escrow_detail',
      'order_sn=' || v_sn,
      v_pid, v_pkey, v_access, v_shop_id
    );

    v_income := v_resp->'response'->'order_income';
    IF v_income IS NOT NULL THEN
      UPDATE shopee_pedidos SET
        selling_price   = (v_income->>'cost_of_goods_sold')::numeric,
        net_commission  = (v_income->>'net_commission_fee')::numeric,
        net_service_fee = (v_income->>'net_service_fee')::numeric,
        shipping_fee    = (v_income->>'actual_shipping_fee')::numeric,
        escrow_amount   = (v_income->>'escrow_amount')::numeric,
        escrow_adjusted = (v_income->>'escrow_amount_after_adjustment')::numeric,
        buyer_total     = (v_income->>'buyer_total_amount')::numeric
      WHERE order_sn = v_sn;
      v_done := v_done + 1;
    ELSE
      v_failed := v_failed + 1;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_remaining
  FROM shopee_pedidos WHERE selling_price IS NULL;

  IF v_done > 0 THEN
    INSERT INTO oauth_refresh_log(conta, http_status, success, message)
    VALUES ('shopee_escrow', 200, true,
      'done=' || v_done || ' failed=' || v_failed || ' remaining=' || v_remaining);
  END IF;

  RETURN jsonb_build_object(
    'processed', v_done,
    'failed',    v_failed,
    'remaining', v_remaining
  );
END $$;

-- 3. shopee_fill_ams: backfill AMS (afiliados) separado, SKIP LOCKED
CREATE OR REPLACE FUNCTION public.shopee_fill_ams(p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_sn     text;
  v_resp   jsonb;
  v_income jsonb;
  v_ams    numeric;
  v_done   int := 0;
  v_remaining int;
BEGIN
  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id
    FROM shopee_oauth_state WHERE id = 1;

  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;

  IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1)
     < clock_timestamp() + interval '10 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
  END IF;

  FOR v_sn IN
    SELECT order_sn FROM shopee_pedidos
    WHERE ams_commission IS NULL
    ORDER BY create_time
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_resp := _sp_api_get(
      '/api/v2/payment/get_escrow_detail',
      'order_sn=' || v_sn,
      v_pid, v_pkey, v_access, v_shop_id
    );

    v_income := v_resp->'response'->'order_income';
    IF v_income IS NOT NULL THEN
      v_ams := COALESCE((v_income->>'order_ams_commission_fee')::numeric, 0);
      UPDATE shopee_pedidos SET ams_commission = v_ams WHERE order_sn = v_sn;
      v_done := v_done + 1;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_remaining
  FROM shopee_pedidos WHERE ams_commission IS NULL;

  RETURN jsonb_build_object(
    'processed', v_done,
    'remaining', v_remaining
  );
END $$;

-- 4. sp_afiliados: RPC para DRE — totais AMS do mês
CREATE OR REPLACE FUNCTION public.sp_afiliados(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH periodo AS (
    SELECT
      (p_month || '-01')::timestamp AT TIME ZONE 'America/Sao_Paulo' AS ini,
      ((p_month || '-01')::date + interval '1 month')::timestamp AT TIME ZONE 'America/Sao_Paulo' AS fim
  )
  SELECT jsonb_build_object(
    'afiliados_total', COALESCE(SUM(p.ams_commission), 0),
    'pedidos_com_ams', COUNT(*) FILTER (WHERE p.ams_commission > 0),
    'pedidos_total',   COUNT(*)
  )
  FROM shopee_pedidos p, periodo
  WHERE p.order_status = 'COMPLETED'
    AND p.create_time >= periodo.ini
    AND p.create_time <  periodo.fim;
$$;

-- 5. shopee_cron_diario: orquestrador diário (list → detail → escrow+AMS)
--    Advisory lock 421982738, reconferência 7 dias, limit 200 escrow/run.
CREATE OR REPLACE FUNCTION public.shopee_cron_diario()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_win_start timestamptz;
  v_win_end   timestamptz;
  v_resp   jsonb;
  v_more   boolean;
  v_cursor text;
  v_page_sns text[];
  v_new_sns  text[];
  v_all_new  text[] := '{}';
  v_batch  text[];
  v_detail jsonb;
  v_order  jsonb;
  v_item   jsonb;
  v_sn     text;
  v_income jsonb;
  v_i int;
  v_listed   int := 0;
  v_inserted int := 0;
  v_escrow_done int := 0;
  v_escrow_fail int := 0;
  v_escrow_remaining int := 0;
BEGIN
  IF NOT pg_try_advisory_lock(421982738) THEN
    RETURN jsonb_build_object('skipped', 'already_running');
  END IF;

  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id
    FROM shopee_oauth_state WHERE id = 1;

  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    PERFORM pg_advisory_unlock(421982738);
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;

  IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1)
     < clock_timestamp() + interval '30 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
  END IF;

  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')
                 AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '7 days';

  -- FASE 1: Listar COMPLETED na janela
  v_more   := true;
  v_cursor := '';
  WHILE v_more LOOP
    v_resp := _sp_api_get(
      '/api/v2/order/get_order_list',
      'time_range_field=create_time'
        || '&time_from=' || extract(epoch from v_win_start)::bigint
        || '&time_to='   || extract(epoch from v_win_end)::bigint
        || '&page_size=100'
        || '&order_status=COMPLETED'
        || CASE WHEN v_cursor <> '' THEN '&cursor=' || v_cursor ELSE '' END,
      v_pid, v_pkey, v_access, v_shop_id
    );

    IF v_resp->>'error' IS NOT NULL AND v_resp->>'error' <> '' THEN
      PERFORM pg_advisory_unlock(421982738);
      RETURN jsonb_build_object('error', v_resp->>'error', 'listed', v_listed);
    END IF;

    IF v_resp->'response'->'order_list' IS NOT NULL THEN
      SELECT array_agg(el->>'order_sn')
      INTO v_page_sns
      FROM jsonb_array_elements(v_resp->'response'->'order_list') AS el;

      IF v_page_sns IS NOT NULL THEN
        v_listed := v_listed + array_length(v_page_sns, 1);

        SELECT array_agg(sn) INTO v_new_sns
        FROM unnest(v_page_sns) AS sn
        WHERE NOT EXISTS (SELECT 1 FROM shopee_pedidos sp WHERE sp.order_sn = sn);

        IF v_new_sns IS NOT NULL THEN
          v_all_new := v_all_new || v_new_sns;
        END IF;
      END IF;
    END IF;

    v_more   := COALESCE((v_resp->'response'->>'more')::boolean, false);
    v_cursor := COALESCE(v_resp->'response'->>'next_cursor', '');
  END LOOP;

  -- FASE 2: Detail dos novos (batches de 50)
  IF array_length(v_all_new, 1) IS NOT NULL AND array_length(v_all_new, 1) > 0 THEN
    v_i := 1;
    WHILE v_i <= array_length(v_all_new, 1) LOOP
      v_batch := v_all_new[v_i : LEAST(v_i + 49, array_length(v_all_new, 1))];

      v_detail := _sp_api_get(
        '/api/v2/order/get_order_detail',
        'order_sn_list=' || array_to_string(v_batch, ',')
          || '&response_optional_fields=item_list',
        v_pid, v_pkey, v_access, v_shop_id
      );

      IF v_detail->'response'->'order_list' IS NOT NULL THEN
        FOR v_order IN
          SELECT value FROM jsonb_array_elements(v_detail->'response'->'order_list')
        LOOP
          INSERT INTO shopee_pedidos (order_sn, create_time, pay_time, order_status)
          VALUES (
            v_order->>'order_sn',
            to_timestamp((v_order->>'create_time')::bigint),
            CASE WHEN (v_order->>'pay_time')::bigint > 0
              THEN to_timestamp((v_order->>'pay_time')::bigint) END,
            v_order->>'order_status'
          )
          ON CONFLICT (order_sn) DO NOTHING;

          FOR v_item IN
            SELECT value FROM jsonb_array_elements(
              COALESCE(v_order->'item_list', '[]'::jsonb))
          LOOP
            INSERT INTO shopee_itens
              (order_sn, item_id, model_id, item_sku, model_sku,
               item_name, quantity, unit_price, original_price)
            VALUES (
              v_order->>'order_sn',
              (v_item->>'item_id')::bigint,
              COALESCE((v_item->>'model_id')::bigint, 0),
              v_item->>'item_sku',
              v_item->>'model_sku',
              v_item->>'item_name',
              COALESCE((v_item->>'model_quantity_purchased')::int, 1),
              (v_item->>'model_discounted_price')::numeric,
              (v_item->>'model_original_price')::numeric
            )
            ON CONFLICT (order_sn, item_id, model_id) DO NOTHING;
          END LOOP;

          v_inserted := v_inserted + 1;
        END LOOP;
      END IF;

      v_i := v_i + 50;
    END LOOP;
  END IF;

  -- FASE 3: Escrow + AMS (limit 200 por run)
  FOR v_sn IN
    SELECT order_sn FROM shopee_pedidos
    WHERE selling_price IS NULL
    ORDER BY create_time
    LIMIT 200
  LOOP
    v_resp := _sp_api_get(
      '/api/v2/payment/get_escrow_detail',
      'order_sn=' || v_sn,
      v_pid, v_pkey, v_access, v_shop_id
    );

    v_income := v_resp->'response'->'order_income';
    IF v_income IS NOT NULL THEN
      UPDATE shopee_pedidos SET
        selling_price   = (v_income->>'cost_of_goods_sold')::numeric,
        net_commission  = (v_income->>'net_commission_fee')::numeric,
        net_service_fee = (v_income->>'net_service_fee')::numeric,
        shipping_fee    = (v_income->>'actual_shipping_fee')::numeric,
        escrow_amount   = (v_income->>'escrow_amount')::numeric,
        escrow_adjusted = (v_income->>'escrow_amount_after_adjustment')::numeric,
        buyer_total     = (v_income->>'buyer_total_amount')::numeric,
        ams_commission  = COALESCE((v_income->>'order_ams_commission_fee')::numeric, 0)
      WHERE order_sn = v_sn;
      v_escrow_done := v_escrow_done + 1;
    ELSE
      v_escrow_fail := v_escrow_fail + 1;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_escrow_remaining
  FROM shopee_pedidos WHERE selling_price IS NULL;

  INSERT INTO oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_cron', 200, true,
    'listed=' || v_listed || ' new=' || v_inserted
    || ' escrow=' || v_escrow_done || ' escrow_fail=' || v_escrow_fail
    || ' escrow_pending=' || v_escrow_remaining);

  PERFORM pg_advisory_unlock(421982738);

  RETURN jsonb_build_object(
    'listed',      v_listed,
    'new_orders',  v_inserted,
    'escrow_done', v_escrow_done,
    'escrow_fail', v_escrow_fail,
    'escrow_pending', v_escrow_remaining
  );
END
$$;

-- 6. Permissões das novas funções
REVOKE ALL ON FUNCTION public.shopee_fill_ams(int)     FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.sp_afiliados(text)       FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.shopee_cron_diario()     FROM public, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.shopee_fill_ams(int)  TO service_role;
GRANT EXECUTE ON FUNCTION public.sp_afiliados(text)    TO service_role;
GRANT EXECUTE ON FUNCTION public.shopee_cron_diario()  TO service_role;

-- 7. Cron diário: 03:30 BRT (06:30 UTC), timeout 600s
SELECT cron.schedule(
  'shopee-diario',
  '30 6 * * *',
  $$SET statement_timeout = '600s'; SELECT shopee_cron_diario()$$
);
