-- shopee_cron_diario: fases resilientes (incidente 05/08/2026).
--
-- O QUE HOUVE: o run das 03:30 BRT falhou com "SSL connection timeout" dentro de
-- shopee_fill_escrow (FASE 3). Como a função inteira roda numa transação única do
-- pg_cron, o ERROR abortou tudo e o ROLLBACK descartou os pedidos de 04/08 já
-- inseridos nas FASES 1–2. Pior: o INSERT em oauth_refresh_log fica no fim da
-- função, então a falha não deixou rastro no log de aplicação — só em
-- cron.job_run_details (pg_cron).
--
-- O FIX (2 mudanças, sem alterar a lógica de negócio de nenhuma fase):
--   1. Cada fase roda num bloco BEGIN/EXCEPTION próprio (subtransação): um erro
--      transiente numa fase perde só o trabalho daquela fase; as demais rodam e
--      COMMITAM. Escrow que falhar é completado pelos jobs das 12:00/18:00 BRT
--      (shopee-escrow-meiodia/tarde), que já existem exatamente pra isso.
--   2. O log em oauth_refresh_log passa a ser escrito SEMPRE (conta 'shopee_cron'),
--      com success=false e o erro de cada fase na mensagem quando algo falhar —
--      a falha fica visível no log de aplicação e no crons_status.
--
-- Erro de API na listagem (FASE 1), que antes dava RETURN precoce sem log, agora
-- vira exceção capturada: registra e segue para escrow/ads/difal.

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
  v_escrow_iter int := 0; v_fase3_ini timestamptz;
  v_today date;
  v_ads_cur jsonb; v_ads_prev jsonb; v_ads_dias int := 0; v_ads_expense numeric := 0;
  v_difal jsonb; v_difal_cnt int := 0;
  -- erro capturado por fase (NULL = fase ok)
  v_err_pedidos text; v_err_escrow text; v_err_ads text; v_err_difal text;
  v_erros text; v_ok boolean;
BEGIN
  IF NOT pg_try_advisory_lock(421982738) THEN
    RETURN jsonb_build_object('skipped', 'already_running');
  END IF;

  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id FROM shopee_oauth_state WHERE id = 1;

  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    INSERT INTO oauth_refresh_log(conta, http_status, success, message)
    VALUES ('shopee_cron', NULL, false, 'missing_credentials');
    PERFORM pg_advisory_unlock(421982738);
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;

  -- Refresh preventivo do token: se falhar, segue com o token atual — as fases
  -- registram individualmente o que não conseguirem fazer.
  BEGIN
    IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1)
       < clock_timestamp() + interval '30 minutes' THEN
      PERFORM shopee_refresh_token(true);
      SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '7 days';

  -- FASES 1+2: listar a janela e inserir pedidos/itens novos
  BEGIN
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
        RAISE EXCEPTION 'get_order_list: %', v_resp->>'error';
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
  EXCEPTION WHEN OTHERS THEN
    v_err_pedidos := SQLERRM;
  END;

  -- FASE 3: Escrow (deducoes) de TODO nao-cancelado sem escrow (inclui em transito).
  -- LOOP CHUNKED (fix de vazao): fill_escrow(100) ate remaining=0, max 12 iters (~1200/dia),
  -- guarda 480s. Se falhar aqui, perde-se só o escrow desta rodada — os jobs
  -- shopee-escrow-meiodia/tarde completam o restante no mesmo dia.
  BEGIN
    v_fase3_ini := clock_timestamp();
    LOOP
      v_esc := shopee_fill_escrow(100);
      v_escrow_done      := v_escrow_done + COALESCE((v_esc->>'processed')::int, 0);
      v_escrow_fail      := v_escrow_fail + COALESCE((v_esc->>'failed')::int, 0);
      v_escrow_remaining := COALESCE((v_esc->>'remaining')::int, 0);
      v_escrow_iter := v_escrow_iter + 1;
      EXIT WHEN v_escrow_remaining = 0
             OR COALESCE((v_esc->>'processed')::int, 0) = 0
             OR v_escrow_iter >= 12
             OR clock_timestamp() - v_fase3_ini > interval '480 seconds';
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    v_err_escrow := SQLERRM;
  END;

  -- FASE 4: ADS
  v_today := (clock_timestamp() AT TIME ZONE 'America/Sao_Paulo')::date;
  BEGIN
    v_ads_cur  := shopee_fill_ads(date_trunc('month', v_today)::date, v_today);
    v_ads_prev := shopee_fill_ads(date_trunc('month', v_today - interval '1 month')::date, (date_trunc('month', v_today)::date - 1));
    v_ads_dias    := COALESCE((v_ads_cur->>'dias')::int, 0) + COALESCE((v_ads_prev->>'dias')::int, 0);
    v_ads_expense := COALESCE((v_ads_cur->>'expense_total')::numeric, 0) + COALESCE((v_ads_prev->>'expense_total')::numeric, 0);
  EXCEPTION WHEN OTHERS THEN
    v_err_ads := SQLERRM;
  END;

  -- FASE 5: DIFAL
  BEGIN
    v_difal := shopee_fill_difal((v_today - interval '16 days')::timestamptz, (v_today + interval '1 day')::timestamptz);
    v_difal_cnt := COALESCE((v_difal->>'difal_cobrancas')::int, 0);
  EXCEPTION WHEN OTHERS THEN
    v_err_difal := SQLERRM;
  END;

  -- Log SEMPRE (sucesso ou falha) — concat_ws descarta os NULL das fases ok.
  v_erros := concat_ws(' | ',
    'pedidos: ' || v_err_pedidos,
    'escrow: '  || v_err_escrow,
    'ads: '     || v_err_ads,
    'difal: '   || v_err_difal);
  v_ok := (v_erros IS NULL OR v_erros = '');

  INSERT INTO oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_cron', CASE WHEN v_ok THEN 200 END, v_ok,
    'listed=' || v_listed || ' new=' || v_inserted
    || ' escrow=' || v_escrow_done || ' escrow_fail=' || v_escrow_fail
    || ' escrow_pending=' || v_escrow_remaining || ' escrow_iters=' || v_escrow_iter
    || ' ads_dias=' || v_ads_dias || ' ads_expense=' || round(v_ads_expense, 2)
    || ' difal_cobrancas=' || v_difal_cnt
    || CASE WHEN v_ok THEN '' ELSE ' ERROS: ' || v_erros END);

  PERFORM pg_advisory_unlock(421982738);

  RETURN jsonb_build_object(
    'listed', v_listed, 'new_orders', v_inserted,
    'escrow_done', v_escrow_done, 'escrow_fail', v_escrow_fail, 'escrow_pending', v_escrow_remaining,
    'escrow_iters', v_escrow_iter,
    'ads_dias', v_ads_dias, 'ads_expense', round(v_ads_expense, 2),
    'difal_cobrancas', v_difal_cnt,
    'erros', CASE WHEN v_ok THEN NULL ELSE v_erros END);
END $function$;
