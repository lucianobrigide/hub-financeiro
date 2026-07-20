-- Fix de vazão do fill de escrow da Shopee.
--
-- BUG: o marcador de "pendente" era `escrow_adjusted IS NULL` e o fill processava do
-- pedido mais ANTIGO pro mais novo. Como ~1.448 pedidos de julho já tinham escrow_amount
-- (base da M.C.) mas ficavam com escrow_adjusted NULL (ajuste final da Shopee posta dias
-- depois), eles ficavam PRESOS na fila e eram re-buscados todo dia — estourando o teto de
-- 12 iterações do cron (1.200 chamadas/dia) SEM NUNCA chegar nos pedidos novos. Resultado:
-- os pedidos do dia mais recente ficavam sem income → a retenção da Shopee era estimada como
-- ~100% → a M.C. do canal despencava artificialmente (ex.: jul/26 aparecia −R$17,6k quando
-- o correto, com tudo liquidado, é ≈ +R$3,9k).
--
-- FIX (equilibrado):
--  (1) PRIORIDADE: pedidos nunca buscados (escrow_amount IS NULL) — a M.C. (sp_repasse) depende disso.
--  (2) CARONA: re-busca pedidos recentes (<=45d) ainda sem ajuste final (escrow_adjusted IS NULL)
--      pra capturar devoluções que postam depois — sp_custo_devolucoes usa (escrow_amount - escrow_adjusted).
--  Ordena nunca-buscados primeiro e do mais novo pro mais antigo.
--  `remaining` conta SÓ os nunca-buscados: o loop do cron encerra assim que a M.C. está em dia,
--  e a re-busca de ajuste anda throttled (pega carona no limite de cada lote), sem desperdício.
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
    WHERE order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      AND ( escrow_amount IS NULL
            OR (escrow_adjusted IS NULL AND create_time > clock_timestamp() - interval '45 days') )
    ORDER BY (escrow_amount IS NOT NULL), create_time DESC
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

  -- remaining = SÓ os nunca-buscados (prioridade da M.C.). A re-busca de ajuste pega carona.
  SELECT COUNT(*) INTO v_remaining FROM shopee_pedidos
  WHERE escrow_amount IS NULL
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING');

  IF v_done > 0 THEN
    INSERT INTO oauth_refresh_log(conta, http_status, success, message)
    VALUES ('shopee_escrow', 200, true, 'done=' || v_done || ' failed=' || v_failed || ' remaining=' || v_remaining);
  END IF;
  RETURN jsonb_build_object('processed', v_done, 'failed', v_failed, 'remaining', v_remaining);
END $function$;
