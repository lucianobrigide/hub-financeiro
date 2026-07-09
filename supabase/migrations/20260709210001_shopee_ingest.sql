-- ============================================================
-- Shopee: tabelas de pedidos/itens + ingestão + DRE RPCs
-- Molde ML/Amazon. Competência: create_time BRT. Régua: COMPLETED.
-- ============================================================

-- 0. Dependência: unaccent para normalizar SKUs com cedilha
CREATE EXTENSION IF NOT EXISTS unaccent;

-- 1. Tabela de pedidos Shopee
CREATE TABLE IF NOT EXISTS public.shopee_pedidos (
  order_sn        text PRIMARY KEY,
  create_time     timestamptz NOT NULL,
  pay_time        timestamptz,
  order_status    text NOT NULL,
  -- escrow (preenchido por shopee_fill_escrow)
  selling_price   numeric(12,2),
  net_commission  numeric(12,2),
  net_service_fee numeric(12,2),
  shipping_fee    numeric(12,2),
  escrow_amount   numeric(12,2),
  escrow_adjusted numeric(12,2),
  buyer_total     numeric(12,2),
  inserted_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.shopee_pedidos ENABLE ROW LEVEL SECURITY;

-- 2. Tabela de itens Shopee (para CMV via ml_custo_produto)
CREATE TABLE IF NOT EXISTS public.shopee_itens (
  order_sn       text NOT NULL REFERENCES shopee_pedidos(order_sn),
  item_id        bigint NOT NULL,
  model_id       bigint NOT NULL DEFAULT 0,
  item_sku       text,
  model_sku      text,
  item_name      text,
  quantity       int NOT NULL DEFAULT 1,
  unit_price     numeric(12,2),
  original_price numeric(12,2),
  PRIMARY KEY (order_sn, item_id, model_id)
);
ALTER TABLE public.shopee_itens ENABLE ROW LEVEL SECURITY;

-- 3. Helper interno: GET assinado com creds pré-lidas (evita vault a cada call).
--    Usa clock_timestamp() para timestamp fresco em chamadas longas.
CREATE OR REPLACE FUNCTION public._sp_api_get(
  p_path text, p_extra text,
  p_pid text, p_pkey text, p_access text, p_shop_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_ts   bigint;
  v_base text;
  v_sign text;
  v_url  text;
  v_status int;
  v_raw  text;
  v_json jsonb;
BEGIN
  v_ts   := extract(epoch from clock_timestamp())::bigint;
  v_base := p_pid || p_path || v_ts::text || p_access || p_shop_id::text;
  v_sign := encode(extensions.hmac(v_base, p_pkey, 'sha256'), 'hex');

  v_url := 'https://partner.shopeemobile.com' || p_path
    || '?partner_id='   || p_pid
    || '&timestamp='    || v_ts
    || '&access_token=' || p_access
    || '&shop_id='      || p_shop_id
    || '&sign='         || v_sign;

  IF p_extra IS NOT NULL AND p_extra <> '' THEN
    v_url := v_url || '&' || p_extra;
  END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  SELECT r.status, r.content INTO v_status, v_raw
  FROM extensions.http_get(v_url) AS r;

  IF v_status <> 200 THEN
    RETURN jsonb_build_object('error', 'http_' || v_status,
                              'body', left(coalesce(v_raw, ''), 500));
  END IF;

  IF left(coalesce(v_raw, ''), 1) <> '{' THEN
    RETURN jsonb_build_object('error', 'invalid_json',
                              'body', left(coalesce(v_raw, ''), 200));
  END IF;

  v_json := v_raw::jsonb;

  IF v_json->>'error' IS NOT NULL AND v_json->>'error' <> '' THEN
    RETURN jsonb_build_object('error', v_json->>'error',
                              'message', v_json->>'message');
  END IF;

  RETURN v_json;
END $$;

-- 4. Fase 1: listar pedidos COMPLETED + buscar detalhes (itens).
--    Rápida (~2 min p/ 4000 pedidos). NÃO busca escrow (fase 2).
CREATE OR REPLACE FUNCTION public.shopee_ingest_orders(p_month text DEFAULT '2026-06')
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'vault'
SET statement_timeout TO '300s'
AS $$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_month_start timestamptz;
  v_month_end   timestamptz;
  v_win_start   timestamptz;
  v_win_end     timestamptz;
  v_resp    jsonb;
  v_more    boolean;
  v_cursor  text;
  v_page_sns text[];
  v_new_sns  text[];
  v_all_sns  text[] := '{}';
  v_batch   text[];
  v_detail  jsonb;
  v_order   jsonb;
  v_item    jsonb;
  v_total_listed   int := 0;
  v_total_detailed int := 0;
  v_i int;
BEGIN
  SELECT decrypted_secret INTO v_pid  FROM vault.decrypted_secrets WHERE name = 'shopee_partner_id';
  SELECT decrypted_secret INTO v_pkey FROM vault.decrypted_secrets WHERE name = 'shopee_partner_key';
  SELECT access_token, shop_id INTO v_access, v_shop_id
    FROM shopee_oauth_state WHERE id = 1;

  IF v_pid IS NULL OR v_pkey IS NULL OR v_access IS NULL THEN
    RETURN jsonb_build_object('error', 'missing_credentials');
  END IF;

  IF (SELECT expires_at FROM shopee_oauth_state WHERE id = 1)
     < clock_timestamp() + interval '30 minutes' THEN
    PERFORM shopee_refresh_token(true);
    SELECT access_token INTO v_access FROM shopee_oauth_state WHERE id = 1;
  END IF;

  -- Limites do mês em BRT (UTC-3)
  v_month_start := ((p_month || '-01')::timestamp) AT TIME ZONE 'America/Sao_Paulo';
  v_month_end   := (((p_month || '-01')::date + interval '1 month')::timestamp)
                    AT TIME ZONE 'America/Sao_Paulo';

  -- Iterar janelas de ≤15 dias
  v_win_start := v_month_start;
  WHILE v_win_start < v_month_end LOOP
    v_win_end := LEAST(v_win_start + interval '15 days', v_month_end);

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
        RETURN jsonb_build_object('error', v_resp->>'error',
                                  'listed', v_total_listed,
                                  'message', v_resp->>'message');
      END IF;

      IF v_resp->'response'->'order_list' IS NOT NULL THEN
        SELECT array_agg(el->>'order_sn')
        INTO v_page_sns
        FROM jsonb_array_elements(v_resp->'response'->'order_list') AS el;

        IF v_page_sns IS NOT NULL THEN
          v_total_listed := v_total_listed + array_length(v_page_sns, 1);

          SELECT array_agg(sn) INTO v_new_sns
          FROM unnest(v_page_sns) AS sn
          WHERE NOT EXISTS (
            SELECT 1 FROM shopee_pedidos sp WHERE sp.order_sn = sn
          );
          IF v_new_sns IS NOT NULL THEN
            v_all_sns := v_all_sns || v_new_sns;
          END IF;
        END IF;
      END IF;

      v_more   := COALESCE((v_resp->'response'->>'more')::boolean, false);
      v_cursor := COALESCE(v_resp->'response'->>'next_cursor', '');
    END LOOP;

    v_win_start := v_win_end;
  END LOOP;

  -- Nada novo → retorna
  IF array_length(v_all_sns, 1) IS NULL OR array_length(v_all_sns, 1) = 0 THEN
    RETURN jsonb_build_object('listed', v_total_listed, 'detailed', 0, 'new_orders', 0);
  END IF;

  -- Buscar detalhes em lotes de 50 (limite da API)
  v_i := 1;
  WHILE v_i <= array_length(v_all_sns, 1) LOOP
    v_batch := v_all_sns[v_i : LEAST(v_i + 49, array_length(v_all_sns, 1))];

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

        v_total_detailed := v_total_detailed + 1;
      END LOOP;
    END IF;

    v_i := v_i + 50;
  END LOOP;

  INSERT INTO oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_ingest', 200, true,
    'orders: listed=' || v_total_listed || ' detailed=' || v_total_detailed);

  RETURN jsonb_build_object(
    'listed',     v_total_listed,
    'detailed',   v_total_detailed,
    'new_orders', COALESCE(array_length(v_all_sns, 1), 0)
  );
END $$;

-- 5. Fase 2: buscar escrow p/ pedidos sem selling_price.
--    Processa p_limit por vez (~200 ≈ 40s). Chamar em loop até remaining=0.
CREATE OR REPLACE FUNCTION public.shopee_fill_escrow(p_limit int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'vault'
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

-- 6. RPCs para DRE (competência: create_time BRT, régua: COMPLETED + escrow)

CREATE OR REPLACE FUNCTION public.sp_faturamento(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'faturamento_bruto', COALESCE(SUM(selling_price), 0),
    'total_pedidos',     COUNT(*)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status = 'COMPLETED'
    AND selling_price IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.sp_comissao(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'comissao_total',     COALESCE(SUM(net_commission + net_service_fee), 0),
    'pedidos_com_escrow', COUNT(*) FILTER (WHERE net_commission IS NOT NULL),
    'pedidos_total',      COUNT(*)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status = 'COMPLETED'
    AND selling_price IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.sp_frete(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'frete_total',       COALESCE(SUM(shipping_fee), 0),
    'pedidos_com_frete', COUNT(*) FILTER (WHERE shipping_fee IS NOT NULL),
    'pedidos_total',     COUNT(*)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status = 'COMPLETED'
    AND selling_price IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.sp_cmv(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'cmv_total',      COALESCE(SUM(c.custo * i.quantity), 0),
    'itens_com_custo', COUNT(*) FILTER (WHERE c.custo IS NOT NULL),
    'itens_total',     COUNT(*)
  )
  FROM public.shopee_itens i
  JOIN public.shopee_pedidos p ON p.order_sn = i.order_sn
  LEFT JOIN public.ml_custo_produto c
    ON c.sku = unaccent(COALESCE(NULLIF(i.model_sku, ''), i.item_sku))
  WHERE to_char(p.create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND p.order_status = 'COMPLETED'
    AND p.selling_price IS NOT NULL;
$$;

-- 7. Permissões: só service_role
REVOKE ALL ON TABLE public.shopee_pedidos FROM public, anon, authenticated;
REVOKE ALL ON TABLE public.shopee_itens   FROM public, anon, authenticated;

REVOKE ALL ON FUNCTION public._sp_api_get(text,text,text,text,text,bigint) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.shopee_ingest_orders(text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.shopee_fill_escrow(int)    FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.sp_faturamento(text)       FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.sp_comissao(text)          FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.sp_frete(text)             FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.sp_cmv(text)               FROM public, anon, authenticated;

GRANT EXECUTE ON FUNCTION public._sp_api_get(text,text,text,text,text,bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.shopee_ingest_orders(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.shopee_fill_escrow(int)    TO service_role;
GRANT EXECUTE ON FUNCTION public.sp_faturamento(text)       TO service_role;
GRANT EXECUTE ON FUNCTION public.sp_comissao(text)          TO service_role;
GRANT EXECUTE ON FUNCTION public.sp_frete(text)             TO service_role;
GRANT EXECUTE ON FUNCTION public.sp_cmv(text)               TO service_role;
