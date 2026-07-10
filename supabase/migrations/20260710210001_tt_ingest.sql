-- ============================================================
-- TikTok Shop: tabelas de pedidos/itens + ingestão (Opção B, by-order) + DRE RPCs
-- Molde Shopee/ML. Competência: create_time BRT. Régua: não-cancelado + liquidado.
-- Finance por pedido via Get Transactions by Order (/finance/202501/orders/{id}/statement_transactions).
-- Gateway HMAC: tt_sign + shop_cipher. ADS/Afiliados vêm INLINE no fee breakdown.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS unaccent;

-- 1. Pedidos TikTok (topo + finance by-order)
CREATE TABLE IF NOT EXISTS public.tt_pedidos (
  order_id       text PRIMARY KEY,
  create_time    timestamptz NOT NULL,
  order_status   text NOT NULL,
  currency       text,
  payment_total  numeric(12,2),
  fin_filled     boolean NOT NULL DEFAULT false,
  fin_revenue    numeric(12,2),
  fin_settlement numeric(12,2),
  fin_frete      numeric(12,2),
  fin_fee_tax    numeric(12,2),
  fin_commission numeric(12,2),
  fin_breakdown  jsonb,               -- soma fee+tax por chave (classifica ads/afiliados/taxas)
  fin_rev_breakdown jsonb,            -- soma revenue_breakdown por chave (extrai devolução/refund)
  fin_attempts   int NOT NULL DEFAULT 0,
  inserted_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tt_pedidos ENABLE ROW LEVEL SECURITY;

-- 2. Itens TikTok (1 linha por line_item; seller_sku para CMV)
CREATE TABLE IF NOT EXISTS public.tt_itens (
  order_id        text NOT NULL REFERENCES public.tt_pedidos(order_id),
  line_item_id    text NOT NULL,
  seller_sku      text,
  sku_id          text,
  product_name    text,
  line_status     text,
  sale_price      numeric(12,2),
  original_price  numeric(12,2),
  seller_discount numeric(12,2),
  quantity        int NOT NULL DEFAULT 1,
  PRIMARY KEY (order_id, line_item_id)
);
ALTER TABLE public.tt_itens ENABLE ROW LEVEL SECURITY;

-- 3. Helpers assinados (creds pré-lidas; timestamp fresco por chamada)
CREATE OR REPLACE FUNCTION public._tt_get(
  p_path text, p_extra jsonb, p_app_key text, p_app_secret text, p_access text, p_cipher text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions'
AS $$
DECLARE v_ts bigint; v_params jsonb; v_sign text; v_qs text; v_url text; v_status int; v_raw text;
BEGIN
  v_ts := extract(epoch from clock_timestamp())::bigint;
  v_params := jsonb_build_object('app_key',p_app_key,'timestamp',v_ts::text,'shop_cipher',p_cipher) || p_extra;
  v_sign := public.tt_sign(p_path, v_params, p_app_secret);
  SELECT string_agg(kv.key||'='||kv.value,'&' ORDER BY kv.key) FROM jsonb_each_text(v_params) kv INTO v_qs;
  v_url := 'https://open-api.tiktokglobalshop.com'||p_path||'?'||v_qs||'&sign='||v_sign;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','20000');
  SELECT r.status, r.content INTO v_status, v_raw
  FROM extensions.http(('GET', v_url, array[extensions.http_header('x-tts-access-token',p_access)], null, null)::extensions.http_request) r;
  IF v_status <> 200 OR left(coalesce(v_raw,''),1) <> '{' THEN
    RETURN jsonb_build_object('error','http_'||v_status,'body',left(coalesce(v_raw,''),300));
  END IF;
  RETURN v_raw::jsonb;
END $$;

CREATE OR REPLACE FUNCTION public._tt_post(
  p_path text, p_extra jsonb, p_body text, p_app_key text, p_app_secret text, p_access text, p_cipher text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions'
AS $$
DECLARE v_ts bigint; v_params jsonb; v_sign text; v_qs text; v_url text; v_status int; v_raw text;
BEGIN
  v_ts := extract(epoch from clock_timestamp())::bigint;
  v_params := jsonb_build_object('app_key',p_app_key,'timestamp',v_ts::text,'shop_cipher',p_cipher) || p_extra;
  v_sign := public.tt_sign(p_path, v_params, p_app_secret, p_body);
  SELECT string_agg(kv.key||'='||kv.value,'&' ORDER BY kv.key) FROM jsonb_each_text(v_params) kv INTO v_qs;
  v_url := 'https://open-api.tiktokglobalshop.com'||p_path||'?'||v_qs||'&sign='||v_sign;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','20000');
  SELECT r.status, r.content INTO v_status, v_raw
  FROM extensions.http(('POST', v_url, array[extensions.http_header('x-tts-access-token',p_access)], 'application/json', p_body)::extensions.http_request) r;
  IF v_status <> 200 OR left(coalesce(v_raw,''),1) <> '{' THEN
    RETURN jsonb_build_object('error','http_'||v_status,'body',left(coalesce(v_raw,''),300));
  END IF;
  RETURN v_raw::jsonb;
END $$;

-- Assinador POST standalone (usado em probes/manuais)
CREATE OR REPLACE FUNCTION public.tt_signed_post(p_path text, p_extra jsonb DEFAULT '{}', p_body text DEFAULT '')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','vault'
AS $$
DECLARE v_app_key text; v_app_secret text; v_access text; v_cipher text; v_ts bigint; v_params jsonb; v_sign text; v_qs text;
BEGIN
  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_app_secret IS NULL THEN RETURN jsonb_build_object('error','missing_credentials'); END IF;
  IF v_access IS NULL THEN RETURN jsonb_build_object('error','not_authorized'); END IF;
  v_ts := extract(epoch from clock_timestamp())::bigint;
  v_params := jsonb_build_object('app_key',v_app_key,'timestamp',v_ts::text,'shop_cipher',v_cipher) || p_extra;
  v_sign := public.tt_sign(p_path, v_params, v_app_secret, p_body);
  SELECT string_agg(kv.key||'='||kv.value,'&' ORDER BY kv.key) FROM jsonb_each_text(v_params) kv INTO v_qs;
  RETURN jsonb_build_object('full_url','https://open-api.tiktokglobalshop.com'||p_path||'?'||v_qs||'&sign='||v_sign,
                            'body', p_body, 'access_token', v_access);
END $$;

-- 4. Ingestão by-order: Order Search por create_time (paginado, idempotente)
CREATE OR REPLACE FUNCTION public.tt_ingest_orders(p_month text DEFAULT '2026-06')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','vault'
SET statement_timeout TO '300s'
AS $$
DECLARE
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_ge bigint; v_lt bigint; v_body text;
  v_resp jsonb; v_token text := ''; v_more boolean := true;
  v_order jsonb; v_item jsonb;
  v_orders int := 0; v_items int := 0; v_pages int := 0;
BEGIN
  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_access IS NULL THEN RETURN jsonb_build_object('error','missing_credentials'); END IF;

  IF (SELECT expires_at FROM public.tt_oauth_state WHERE id=1) < clock_timestamp() + interval '30 minutes' THEN
    PERFORM public.tt_refresh_token(true);
    SELECT access_token INTO v_access FROM public.tt_oauth_state WHERE id=1;
  END IF;

  v_ge := extract(epoch from ((p_month||'-01')::timestamp) at time zone 'America/Sao_Paulo')::bigint;
  v_lt := extract(epoch from (((p_month||'-01')::date + interval '1 month')::timestamp) at time zone 'America/Sao_Paulo')::bigint;
  v_body := json_build_object('create_time_ge',v_ge,'create_time_lt',v_lt)::text;

  WHILE v_more LOOP
    v_resp := public._tt_post('/order/202309/orders/search',
      jsonb_build_object('page_size','100') || CASE WHEN v_token<>'' THEN jsonb_build_object('page_token',v_token) ELSE '{}'::jsonb END,
      v_body, v_app_key, v_app_secret, v_access, v_cipher);

    IF v_resp->>'error' IS NOT NULL THEN
      RETURN jsonb_build_object('error',v_resp->>'error','body',v_resp->>'body','orders',v_orders,'pages',v_pages);
    END IF;
    IF (v_resp->>'code')::int <> 0 THEN
      RETURN jsonb_build_object('error','api_'||(v_resp->>'code'),'message',v_resp->>'message','orders',v_orders);
    END IF;

    v_pages := v_pages + 1;

    FOR v_order IN SELECT value FROM jsonb_array_elements(coalesce(v_resp->'data'->'orders','[]'::jsonb)) LOOP
      INSERT INTO public.tt_pedidos (order_id, create_time, order_status, currency, payment_total)
      VALUES (
        v_order->>'id',
        to_timestamp((v_order->>'create_time')::bigint),
        v_order->>'status',
        v_order->'payment'->>'currency',
        nullif(v_order->'payment'->>'total_amount','')::numeric
      )
      ON CONFLICT (order_id) DO UPDATE
        SET order_status = excluded.order_status,
            payment_total = excluded.payment_total;
      v_orders := v_orders + 1;

      FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_order->'line_items','[]'::jsonb)) LOOP
        INSERT INTO public.tt_itens (order_id, line_item_id, seller_sku, sku_id, product_name, line_status, sale_price, original_price, seller_discount, quantity)
        VALUES (
          v_order->>'id', v_item->>'id', v_item->>'seller_sku', v_item->>'sku_id', v_item->>'product_name',
          v_item->>'display_status',
          nullif(v_item->>'sale_price','')::numeric,
          nullif(v_item->>'original_price','')::numeric,
          nullif(v_item->>'seller_discount','')::numeric, 1
        )
        ON CONFLICT (order_id, line_item_id) DO UPDATE SET line_status = excluded.line_status;
        v_items := v_items + 1;
      END LOOP;
    END LOOP;

    v_token := coalesce(v_resp->'data'->>'next_page_token','');
    v_more := v_token <> '';
  END LOOP;

  INSERT INTO public.oauth_refresh_log(conta,http_status,success,message)
  VALUES ('tt_ingest',200,true,'orders='||v_orders||' items='||v_items||' pages='||v_pages||' month='||p_month);

  RETURN jsonb_build_object('orders',v_orders,'items',v_items,'pages',v_pages,'month',p_month);
END $$;

-- 5. Enriquecimento finance by-order (comissão/fee+tax/frete/breakdown). Lotes; até 3 tentativas.
CREATE OR REPLACE FUNCTION public.tt_fill_finance(p_limit int DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','vault'
SET statement_timeout TO '300s'
AS $$
DECLARE
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_id text; v_resp jsonb; v_data jsonb; v_bd jsonb; v_rb jsonb;
  v_done int := 0; v_empty int := 0; v_fail int := 0; v_remaining int;
BEGIN
  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_access IS NULL THEN RETURN jsonb_build_object('error','missing_credentials'); END IF;

  IF (SELECT expires_at FROM public.tt_oauth_state WHERE id=1) < clock_timestamp() + interval '15 minutes' THEN
    PERFORM public.tt_refresh_token(true);
    SELECT access_token INTO v_access FROM public.tt_oauth_state WHERE id=1;
  END IF;

  FOR v_id IN
    SELECT order_id FROM public.tt_pedidos
    WHERE fin_filled = false AND order_status <> 'CANCELLED' AND fin_attempts < 3
    ORDER BY create_time LIMIT p_limit
  LOOP
    UPDATE public.tt_pedidos SET fin_attempts = fin_attempts + 1 WHERE order_id = v_id;

    v_resp := public._tt_get('/finance/202501/orders/'||v_id||'/statement_transactions',
      '{}'::jsonb, v_app_key, v_app_secret, v_access, v_cipher);

    IF v_resp->>'error' IS NOT NULL OR (v_resp->>'code')::int <> 0 THEN
      v_fail := v_fail + 1; CONTINUE;
    END IF;

    v_data := v_resp->'data';
    IF v_data IS NULL OR v_data->>'revenue_amount' IS NULL OR v_data->'sku_transactions' IS NULL THEN
      v_empty := v_empty + 1; CONTINUE;                 -- ainda não liquidado
    END IF;

    SELECT jsonb_object_agg(k, s) INTO v_bd FROM (
      SELECT kv.key k, sum(kv.value::numeric) s
      FROM jsonb_array_elements(v_data->'sku_transactions') st,
           LATERAL (
             SELECT * FROM jsonb_each_text(coalesce(st->'fee_tax_breakdown'->'fee','{}'::jsonb))
             UNION ALL
             SELECT * FROM jsonb_each_text(coalesce(st->'fee_tax_breakdown'->'tax','{}'::jsonb))
           ) kv
      GROUP BY kv.key
    ) t;

    -- soma revenue_breakdown por chave (extrai devolução/refund)
    SELECT jsonb_object_agg(k, s) INTO v_rb FROM (
      SELECT kv.key k, sum(kv.value::numeric) s
      FROM jsonb_array_elements(v_data->'sku_transactions') st,
           LATERAL jsonb_each_text(coalesce(st->'revenue_breakdown','{}'::jsonb)) kv
      GROUP BY kv.key
    ) t;

    UPDATE public.tt_pedidos SET
      fin_filled        = true,
      fin_revenue       = nullif(v_data->>'revenue_amount','')::numeric,
      fin_settlement    = nullif(v_data->>'settlement_amount','')::numeric,
      fin_frete         = nullif(v_data->>'shipping_cost_amount','')::numeric,
      fin_fee_tax       = nullif(v_data->>'fee_and_tax_amount','')::numeric,
      fin_commission    = coalesce((v_bd->>'platform_commission_amount')::numeric, 0),
      fin_breakdown     = v_bd,
      fin_rev_breakdown = v_rb
    WHERE order_id = v_id;
    v_done := v_done + 1;
  END LOOP;

  SELECT count(*) INTO v_remaining FROM public.tt_pedidos
    WHERE fin_filled=false AND order_status<>'CANCELLED' AND fin_attempts<3;

  RETURN jsonb_build_object('done',v_done,'empty_nao_liquidado',v_empty,'fail',v_fail,'remaining',v_remaining);
END $$;

-- 6. RPCs do DRE (competência create_time BRT; régua não-cancelado + liquidado)
-- Bruta = gross antes da devolução; líquido = revenue_amount (base da M.C.); devoluções explícitas.
CREATE OR REPLACE FUNCTION public.tt_faturamento(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH b AS (
    SELECT
      sum(fin_revenue) AS revenue,
      sum( coalesce((fin_rev_breakdown->>'refund_subtotal_before_discount_amount')::numeric,0)
         + coalesce((fin_rev_breakdown->>'seller_discount_refund_amount')::numeric,0) ) AS refund_net,
      count(*) AS pedidos,
      sum(fin_settlement) AS settlement
    FROM public.tt_pedidos
    WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo','YYYY-MM')=p_month
      AND order_status<>'CANCELLED' AND fin_filled
  )
  SELECT jsonb_build_object(
    'faturamento_bruto',   coalesce(revenue - refund_net, 0),  -- gross antes da devolução
    'devolucoes',          coalesce(-refund_net, 0),           -- magnitude positiva (linha própria)
    'faturamento_liquido', coalesce(revenue, 0),               -- = revenue_amount (base da M.C.)
    'total_pedidos',       coalesce(pedidos, 0),
    'settlement',          coalesce(settlement, 0)
  ) FROM b;
$$;

CREATE OR REPLACE FUNCTION public.tt_deducoes(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  WITH b AS (
    SELECT
      -sum(fin_commission) AS comissao,
      -sum(coalesce((fin_breakdown->>'affiliate_commission_amount')::numeric,0)) AS afiliados,
      -sum(
         coalesce((fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
       + coalesce((fin_breakdown->>'gmv_max_ad_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'smart_promotion_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'tap_shop_ads_commission')::numeric,0)
       + coalesce((fin_breakdown->>'cps_shop_ads_commission_tax_amount')::numeric,0)
       + coalesce((fin_breakdown->>'brand_amplification_program_commission')::numeric,0)
       + coalesce((fin_breakdown->>'brand_campaign_fee')::numeric,0)
       + coalesce((fin_breakdown->>'category_led_campaign_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'campaign_period_fee_cfp_amount')::numeric,0)
       + coalesce((fin_breakdown->>'campaign_period_fee_sp_amount')::numeric,0)
       + coalesce((fin_breakdown->>'live_specials_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'flash_sales_service_fee_amount')::numeric,0)
       + coalesce((fin_breakdown->>'cofunded_creator_bonus_amount')::numeric,0)
       + coalesce((fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0)
      ) AS ads,
      -sum(fin_frete) AS frete,
      -sum(fin_fee_tax) AS fee_tax_total,
      count(*) AS pedidos
    FROM public.tt_pedidos
    WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo','YYYY-MM')=p_month
      AND order_status<>'CANCELLED' AND fin_filled
  )
  SELECT jsonb_build_object(
    'comissao',  coalesce(comissao,0),
    'afiliados', coalesce(afiliados,0),
    'ads',       coalesce(ads,0),
    'frete',     coalesce(frete,0),
    'taxas',     coalesce(fee_tax_total - comissao - afiliados - ads,0),  -- residual → reconcilia exato
    'pedidos',   coalesce(pedidos,0)
  ) FROM b;
$$;

CREATE OR REPLACE FUNCTION public.tt_cmv(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'cmv_total',       coalesce(sum(c.custo*i.quantity),0),
    'itens_com_custo', count(c.custo),
    'itens_total',     count(*)
  )
  FROM public.tt_itens i
  JOIN public.tt_pedidos p ON p.order_id=i.order_id
  LEFT JOIN public.ml_custo_produto c ON c.sku = unaccent(coalesce(nullif(i.seller_sku,''),''))
  WHERE to_char(p.create_time AT TIME ZONE 'America/Sao_Paulo','YYYY-MM')=p_month
    AND i.line_status<>'CANCELLED' AND p.order_status<>'CANCELLED' AND p.fin_filled;
$$;

-- 7. Permissões: só service_role
REVOKE ALL ON TABLE public.tt_pedidos FROM public, anon, authenticated;
REVOKE ALL ON TABLE public.tt_itens   FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public._tt_get(text,jsonb,text,text,text,text)            FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public._tt_post(text,jsonb,text,text,text,text,text)      FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_signed_post(text,jsonb,text)                    FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_ingest_orders(text)                            FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_fill_finance(int)                              FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_faturamento(text)                              FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_deducoes(text)                                 FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.tt_cmv(text)                                      FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._tt_get(text,jsonb,text,text,text,text)            TO service_role;
GRANT EXECUTE ON FUNCTION public._tt_post(text,jsonb,text,text,text,text,text)      TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_signed_post(text,jsonb,text)                    TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_ingest_orders(text)                            TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_fill_finance(int)                              TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_faturamento(text)                              TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_deducoes(text)                                 TO service_role;
GRANT EXECUTE ON FUNCTION public.tt_cmv(text)                                      TO service_role;
