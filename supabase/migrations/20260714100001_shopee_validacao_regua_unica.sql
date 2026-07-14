-- Shopee — validação: régua única (não-cancelados) + M.C. coerente
-- Deduções (comissão/frete/afiliados/CMV) e bruta sobre TODOS os pedidos não-cancelados
-- (deduções vêm do escrow desde a venda, não só na conclusão). Custo Devoluções = estorno
-- incremental (total_adjustment_amount) das devoluções finalizadas. Cancelado sai limpo.
-- Estado ao vivo do Supabase capturado via pg_get_functiondef (repo <-> banco sincronizado).

-- ===== sp_faturamento =====
CREATE OR REPLACE FUNCTION public.sp_faturamento(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'faturamento_bruto', COALESCE(SUM(selling_price), 0),
    'total_pedidos',     COUNT(*)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND selling_price IS NOT NULL;
$function$
;

-- ===== sp_comissao =====
CREATE OR REPLACE FUNCTION public.sp_comissao(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'comissao_total',     COALESCE(SUM(net_commission + net_service_fee), 0),
    'pedidos_com_escrow', COUNT(*) FILTER (WHERE net_commission IS NOT NULL),
    'pedidos_total',      COUNT(*)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND selling_price IS NOT NULL;
$function$
;

-- ===== sp_frete =====
CREATE OR REPLACE FUNCTION public.sp_frete(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'frete_total',       COALESCE(SUM(shipping_fee), 0),
    'pedidos_com_frete', COUNT(*) FILTER (WHERE shipping_fee IS NOT NULL),
    'pedidos_total',     COUNT(*)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND selling_price IS NOT NULL;
$function$
;

-- ===== sp_afiliados =====
CREATE OR REPLACE FUNCTION public.sp_afiliados(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  WHERE p.order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND p.create_time >= periodo.ini
    AND p.create_time <  periodo.fim;
$function$
;

-- ===== sp_cmv =====
CREATE OR REPLACE FUNCTION public.sp_cmv(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'cmv_total',       COALESCE(SUM(c.custo * i.quantity), 0),
    'itens_com_custo', COUNT(*) FILTER (WHERE c.custo IS NOT NULL),
    'itens_total',     COUNT(*)
  )
  FROM public.shopee_itens i
  JOIN public.shopee_pedidos p ON p.order_sn = i.order_sn
  LEFT JOIN public.ml_custo_produto c
    ON c.sku = unaccent(COALESCE(NULLIF(i.model_sku, ''), i.item_sku))
  WHERE to_char(p.create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND p.order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND p.selling_price IS NOT NULL;
$function$
;

-- ===== sp_custo_devolucoes =====
CREATE OR REPLACE FUNCTION public.sp_custo_devolucoes(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  SELECT jsonb_build_object(
    'custo_total',        COALESCE(SUM(escrow_amount - escrow_adjusted), 0),
    'pedidos_devolvidos', COUNT(*),
    'receita_devolvida',  COALESCE(SUM(selling_price), 0)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND escrow_amount IS NOT NULL AND escrow_adjusted IS NOT NULL
    AND escrow_adjusted < escrow_amount;
$function$
;

-- ===== shopee_fill_escrow =====
CREATE OR REPLACE FUNCTION public.shopee_fill_escrow(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_sn text; v_resp jsonb; v_income jsonb;
  v_done int := 0; v_failed int := 0; v_remaining int;
BEGIN
  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id FROM shopee_oauth_state WHERE id = 1;
  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;
  IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1) < clock_timestamp() + interval '10 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
  END IF;

  FOR v_sn IN
    SELECT order_sn FROM shopee_pedidos
    WHERE escrow_adjusted IS NULL
      AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    ORDER BY create_time
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_resp := _sp_api_get('/api/v2/payment/get_escrow_detail', 'order_sn=' || v_sn, v_pid, v_pkey, v_access, v_shop_id);
    v_income := v_resp->'response'->'order_income';
    IF v_income IS NOT NULL THEN
      UPDATE shopee_pedidos SET
        selling_price   = COALESCE(selling_price,
                            NULLIF((v_income->>'cost_of_goods_sold')::numeric, 0),
                            (SELECT round(sum(unit_price*quantity),2) FROM shopee_itens WHERE order_sn = v_sn), 0),
        net_commission  = (v_income->>'net_commission_fee')::numeric,
        net_service_fee = (v_income->>'net_service_fee')::numeric,
        shipping_fee    = (v_income->>'actual_shipping_fee')::numeric,
        escrow_amount   = (v_income->>'escrow_amount')::numeric,
        escrow_adjusted = (v_income->>'escrow_amount_after_adjustment')::numeric,
        buyer_total     = (v_income->>'buyer_total_amount')::numeric,
        ams_commission  = COALESCE((v_income->>'order_ams_commission_fee')::numeric, 0)
      WHERE order_sn = v_sn;
      v_done := v_done + 1;
    ELSE v_failed := v_failed + 1;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_remaining FROM shopee_pedidos
  WHERE escrow_adjusted IS NULL
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING');

  IF v_done > 0 THEN
    INSERT INTO oauth_refresh_log(conta, http_status, success, message)
    VALUES ('shopee_escrow', 200, true, 'done=' || v_done || ' failed=' || v_failed || ' remaining=' || v_remaining);
  END IF;
  RETURN jsonb_build_object('processed', v_done, 'failed', v_failed, 'remaining', v_remaining);
END $function$
;

-- ===== shopee_ingest_page =====
CREATE OR REPLACE FUNCTION public.shopee_ingest_page(p_from_ts bigint, p_to_ts bigint, p_cursor text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
 SET statement_timeout TO '120s'
AS $function$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_resp jsonb; v_page_sns text[]; v_new_sns text[]; v_batch text[];
  v_detail jsonb; v_order jsonb; v_item jsonb; v_inserted int := 0; v_i int; v_st text;
BEGIN
  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id FROM shopee_oauth_state WHERE id = 1;
  IF v_access IS NULL THEN RETURN '{"error":"no_token"}'::jsonb; END IF;

  -- SEM order_status => todos os status (para faturamento bruto = todos pedidos realizados)
  v_resp := _sp_api_get(
    '/api/v2/order/get_order_list',
    'time_range_field=create_time'
      || '&time_from=' || p_from_ts
      || '&time_to='   || p_to_ts
      || '&page_size=100'
      || CASE WHEN p_cursor <> '' THEN '&cursor=' || p_cursor ELSE '' END,
    v_pid, v_pkey, v_access, v_shop_id
  );
  IF v_resp->>'error' IS NOT NULL AND v_resp->>'error' <> '' THEN RETURN v_resp; END IF;

  SELECT array_agg(el->>'order_sn') INTO v_page_sns
  FROM jsonb_array_elements(COALESCE(v_resp->'response'->'order_list','[]'::jsonb)) el;
  IF v_page_sns IS NULL THEN
    RETURN jsonb_build_object('listed',0,'inserted',0,'more',false,'cursor','');
  END IF;

  SELECT array_agg(sn) INTO v_new_sns
  FROM unnest(v_page_sns) sn
  WHERE NOT EXISTS (SELECT 1 FROM shopee_pedidos sp WHERE sp.order_sn = sn);

  IF v_new_sns IS NOT NULL AND array_length(v_new_sns,1) > 0 THEN
    v_i := 1;
    WHILE v_i <= array_length(v_new_sns,1) LOOP
      v_batch := v_new_sns[v_i : LEAST(v_i+49, array_length(v_new_sns,1))];
      v_detail := _sp_api_get(
        '/api/v2/order/get_order_detail',
        'order_sn_list=' || array_to_string(v_batch,',') || '&response_optional_fields=item_list',
        v_pid, v_pkey, v_access, v_shop_id
      );
      IF v_detail->'response'->'order_list' IS NOT NULL THEN
        FOR v_order IN SELECT value FROM jsonb_array_elements(v_detail->'response'->'order_list')
        LOOP
          v_st := v_order->>'order_status';
          INSERT INTO shopee_pedidos (order_sn, create_time, pay_time, order_status)
          VALUES (
            v_order->>'order_sn',
            to_timestamp((v_order->>'create_time')::bigint),
            CASE WHEN (v_order->>'pay_time')::bigint > 0 THEN to_timestamp((v_order->>'pay_time')::bigint) END,
            v_st
          ) ON CONFLICT (order_sn) DO NOTHING;

          FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_order->'item_list','[]'::jsonb))
          LOOP
            INSERT INTO shopee_itens
              (order_sn, item_id, model_id, item_sku, model_sku, item_name, quantity, unit_price, original_price)
            VALUES (
              v_order->>'order_sn', (v_item->>'item_id')::bigint, COALESCE((v_item->>'model_id')::bigint, 0),
              v_item->>'item_sku', v_item->>'model_sku', v_item->>'item_name',
              COALESCE((v_item->>'model_quantity_purchased')::int, 1),
              (v_item->>'model_discounted_price')::numeric, (v_item->>'model_original_price')::numeric
            ) ON CONFLICT (order_sn, item_id, model_id) DO NOTHING;
          END LOOP;

          -- Pedido NAO concluido nao tem escrow ainda -> bruta vem dos itens (unit_price*qty).
          -- COMPLETED fica com selling_price NULL para o escrow preencher (comissao/frete/etc).
          IF v_st <> 'COMPLETED' THEN
            UPDATE shopee_pedidos SET selling_price = (
              SELECT round(sum(unit_price*quantity),2) FROM shopee_itens WHERE order_sn = v_order->>'order_sn'
            ) WHERE order_sn = v_order->>'order_sn';
          END IF;
          v_inserted := v_inserted + 1;
        END LOOP;
      END IF;
      v_i := v_i + 50;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'listed', array_length(v_page_sns,1),
    'inserted', v_inserted,
    'more', COALESCE((v_resp->'response'->>'more')::boolean, false),
    'cursor', COALESCE(v_resp->'response'->>'next_cursor','')
  );
END $function$
;

-- ===== shopee_cron_diario =====
CREATE OR REPLACE FUNCTION public.shopee_cron_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_more boolean; v_cursor text;
  v_page_sns text[]; v_new_sns text[]; v_all_new text[] := '{}';
  v_batch text[]; v_detail jsonb; v_order jsonb; v_item jsonb;
  v_sn text; v_income jsonb; v_i int; v_st text;
  v_listed int := 0; v_inserted int := 0;
  v_esc jsonb; v_escrow_done int := 0; v_escrow_fail int := 0; v_escrow_remaining int := 0;
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

  -- FASE 1: Listar TODOS os status na janela
  v_more := true; v_cursor := '';
  WHILE v_more LOOP
    v_resp := _sp_api_get('/api/v2/order/get_order_list',
      'time_range_field=create_time'
        || '&time_from=' || extract(epoch from v_win_start)::bigint
        || '&time_to='   || extract(epoch from v_win_end)::bigint
        || '&page_size=100'
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

  -- FASE 2: Detail dos novos + selling_price dos itens p/ nao-concluido
  IF array_length(v_all_new, 1) IS NOT NULL AND array_length(v_all_new, 1) > 0 THEN
    v_i := 1;
    WHILE v_i <= array_length(v_all_new, 1) LOOP
      v_batch := v_all_new[v_i : LEAST(v_i + 49, array_length(v_all_new, 1))];
      v_detail := _sp_api_get('/api/v2/order/get_order_detail',
        'order_sn_list=' || array_to_string(v_batch, ',') || '&response_optional_fields=item_list',
        v_pid, v_pkey, v_access, v_shop_id);
      IF v_detail->'response'->'order_list' IS NOT NULL THEN
        FOR v_order IN SELECT value FROM jsonb_array_elements(v_detail->'response'->'order_list') LOOP
          v_st := v_order->>'order_status';
          INSERT INTO shopee_pedidos (order_sn, create_time, pay_time, order_status)
          VALUES (v_order->>'order_sn', to_timestamp((v_order->>'create_time')::bigint),
            CASE WHEN (v_order->>'pay_time')::bigint > 0 THEN to_timestamp((v_order->>'pay_time')::bigint) END,
            v_st)
          ON CONFLICT (order_sn) DO NOTHING;
          FOR v_item IN SELECT value FROM jsonb_array_elements(COALESCE(v_order->'item_list', '[]'::jsonb)) LOOP
            INSERT INTO shopee_itens (order_sn, item_id, model_id, item_sku, model_sku, item_name, quantity, unit_price, original_price)
            VALUES (v_order->>'order_sn', (v_item->>'item_id')::bigint, COALESCE((v_item->>'model_id')::bigint, 0),
              v_item->>'item_sku', v_item->>'model_sku', v_item->>'item_name',
              COALESCE((v_item->>'model_quantity_purchased')::int, 1),
              (v_item->>'model_discounted_price')::numeric, (v_item->>'model_original_price')::numeric)
            ON CONFLICT (order_sn, item_id, model_id) DO NOTHING;
          END LOOP;
          IF v_st <> 'COMPLETED' THEN
            UPDATE shopee_pedidos SET selling_price = (
              SELECT round(sum(unit_price*quantity),2) FROM shopee_itens WHERE order_sn = v_order->>'order_sn'
            ) WHERE order_sn = v_order->>'order_sn';
          END IF;
          v_inserted := v_inserted + 1;
        END LOOP;
      END IF;
      v_i := v_i + 50;
    END LOOP;
  END IF;

  -- FASE 3: Escrow (deducoes) de TODO nao-cancelado sem escrow (inclui em transito). Via shopee_fill_escrow.
  v_esc := shopee_fill_escrow(200);
  v_escrow_done      := COALESCE((v_esc->>'processed')::int, 0);
  v_escrow_fail      := COALESCE((v_esc->>'failed')::int, 0);
  v_escrow_remaining := COALESCE((v_esc->>'remaining')::int, 0);

  -- FASE 4: ADS
  v_today := (clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date;
  v_ads_cur  := shopee_fill_ads(date_trunc('month', v_today)::date, v_today);
  v_ads_prev := shopee_fill_ads(date_trunc('month', v_today - interval '1 month')::date, (date_trunc('month', v_today)::date - 1));
  v_ads_dias    := COALESCE((v_ads_cur->>'dias')::int, 0) + COALESCE((v_ads_prev->>'dias')::int, 0);
  v_ads_expense := COALESCE((v_ads_cur->>'expense_total')::numeric, 0) + COALESCE((v_ads_prev->>'expense_total')::numeric, 0);

  -- FASE 5: DIFAL
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
END $function$
;

-- ===== shopee_cron_semanal =====
CREATE OR REPLACE FUNCTION public.shopee_cron_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
DECLARE
  v_rec jsonb; v_flip int := 0; v_refinar int := 0;
  v_win_start timestamptz; v_win_end timestamptz;
  v_i int; v_from bigint; v_to bigint;
  v_page jsonb; v_more boolean; v_cursor text; v_guard int;
  v_listed int := 0; v_inserted int := 0;
  v_esc jsonb; v_escrow int := 0;
BEGIN
  IF NOT pg_try_advisory_lock(421982738) THEN
    RETURN jsonb_build_object('skipped','already_running');
  END IF;

  -- FASE 0: reconferencia de cancelados (flipa status stale -> sai da bruta e do CMV)
  v_rec := shopee_reconfere_status(30);
  v_flip := COALESCE((v_rec->>'flipados_no_hub')::int, 0);

  -- FASE 0b: provisorio -> definitivo. Remarca o escrow dos CONCLUIDOS recentes (21d) p/
  -- re-buscar o escrow_amount_after_adjustment final (pega reembolso/ajuste pos-conclusao).
  -- So zera o marcador escrow_adjusted; net_commission/frete continuam (nao some do card).
  -- O fill (FASE 2 + diario) re-busca escrow_adjusted IS NULL -> auto-cicatrizante.
  UPDATE shopee_pedidos SET escrow_adjusted = NULL
  WHERE order_status = 'COMPLETED'
    AND create_time > clock_timestamp() - interval '21 days'
    AND escrow_adjusted IS NOT NULL;
  GET DIAGNOSTICS v_refinar = ROW_COUNT;

  -- FASE 1: re-ingere 30d TODOS os status (late-completers + novos)
  v_win_end := clock_timestamp();
  v_win_start := v_win_end - interval '30 days';
  FOR v_i IN 0..1 LOOP
    v_from := extract(epoch from (v_win_start + (v_i*interval '15 days')))::bigint;
    v_to   := extract(epoch from least(v_win_start + ((v_i+1)*interval '15 days'), v_win_end))::bigint;
    v_more := true; v_cursor := ''; v_guard := 0;
    WHILE v_more AND v_guard < 40 LOOP
      v_page := shopee_ingest_pages(v_from, v_to, v_cursor, 10);
      IF v_page->>'error' IS NOT NULL AND v_page->>'error' <> '' THEN EXIT; END IF;
      v_listed   := v_listed   + COALESCE((v_page->>'listed')::int, 0);
      v_inserted := v_inserted + COALESCE((v_page->>'inserted')::int, 0);
      v_more     := COALESCE((v_page->>'more')::boolean, false);
      v_cursor   := COALESCE(v_page->>'cursor','');
      v_guard := v_guard + 1;
    END LOOP;
  END LOOP;

  -- FASE 2: escrow pendente + remarcados (deducoes de transito + finalizacao dos concluidos)
  v_esc := shopee_fill_escrow(800);
  v_escrow := COALESCE((v_esc->>'processed')::int, 0);

  INSERT INTO oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_cron_semanal', 200, true,
    'reconfere_flip=' || v_flip || ' escrow_remarcados=' || v_refinar
    || ' listed=' || v_listed || ' new=' || v_inserted || ' escrow=' || v_escrow);

  PERFORM pg_advisory_unlock(421982738);

  RETURN jsonb_build_object(
    'reconfere_flipados', v_flip,
    'escrow_remarcados_provisorio_final', v_refinar,
    'listed', v_listed, 'new_orders', v_inserted, 'escrow_done', v_escrow);
END $function$
;

-- ===== shopee_reconfere_status =====
CREATE OR REPLACE FUNCTION public.shopee_reconfere_status(p_dias integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
 SET statement_timeout TO '600s'
AS $function$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_more boolean; v_cursor text; v_page_sns text[];
  v_all text[] := '{}'; v_i int; v_st text; v_flipped int; v_janelas int;
BEGIN
  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name='shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name='shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id FROM shopee_oauth_state WHERE id=1;
  IF v_access IS NULL THEN RETURN '{"error":"no_token"}'::jsonb; END IF;
  IF (SELECT expires_at FROM shopee_oauth_state WHERE id=1) < clock_timestamp() + interval '30 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id=1;
  END IF;

  v_win_end := clock_timestamp();
  v_win_start := v_win_end - (p_dias || ' days')::interval;
  v_janelas := ceil(p_dias / 15.0)::int;  -- API cap 15 dias/chamada

  FOREACH v_st IN ARRAY ARRAY['CANCELLED','IN_CANCEL'] LOOP
    FOR v_i IN 0..(v_janelas-1) LOOP
      v_more := true; v_cursor := '';
      WHILE v_more LOOP
        v_resp := _sp_api_get('/api/v2/order/get_order_list',
          'time_range_field=update_time'
            || '&time_from=' || extract(epoch from least(v_win_start + (v_i*interval '15 days'), v_win_end))::bigint
            || '&time_to='   || extract(epoch from least(v_win_start + ((v_i+1)*interval '15 days'), v_win_end))::bigint
            || '&page_size=100&order_status=' || v_st
            || CASE WHEN v_cursor <> '' THEN '&cursor=' || v_cursor ELSE '' END,
          v_pid, v_pkey, v_access, v_shop_id);
        IF v_resp->>'error' IS NOT NULL AND v_resp->>'error' <> '' THEN
          RETURN jsonb_build_object('error', v_resp->>'error', 'status', v_st);
        END IF;
        SELECT array_agg(el->>'order_sn') INTO v_page_sns
        FROM jsonb_array_elements(coalesce(v_resp->'response'->'order_list','[]'::jsonb)) el;
        IF v_page_sns IS NOT NULL THEN v_all := v_all || v_page_sns; END IF;
        v_more := coalesce((v_resp->'response'->>'more')::boolean, false);
        v_cursor := coalesce(v_resp->'response'->>'next_cursor','');
      END LOOP;
    END LOOP;
  END LOOP;

  -- flipa no Hub os que estao ativos mas ja foram cancelados no ML/Shopee
  UPDATE shopee_pedidos
  SET order_status = 'CANCELLED'
  WHERE order_sn = ANY(v_all)
    AND order_status NOT IN ('CANCELLED','IN_CANCEL');
  GET DIAGNOSTICS v_flipped = ROW_COUNT;

  INSERT INTO oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_reconfere', 200, true,
    'dias=' || p_dias || ' cancelados_listados=' || coalesce(array_length(v_all,1),0) || ' flipados=' || v_flipped);

  RETURN jsonb_build_object(
    'dias', p_dias,
    'cancelados_listados', coalesce(array_length(v_all,1),0),
    'flipados_no_hub', v_flipped
  );
END $function$
;
