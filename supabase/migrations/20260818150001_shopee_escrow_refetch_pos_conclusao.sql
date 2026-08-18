-- =============================================================================
-- Shopee: re-busca do escrow PÓS-CONCLUSÃO (fix da captura de afiliados + drift)
-- 18/08/2026
--
-- Problema: o escrow é fotografado no READY_TO_SHIP e nunca relido. A comissão
-- de afiliados (order_ams_commission_fee) só aparece na resposta perto da
-- conclusão do pedido → ams_commission ficou 0 em todo pedido novo desde
-- ~11/07 (quando o backfill de 09/07 alcançou o tempo real). E não é só o
-- afiliado: o escrow final diverge da 1ª foto em >50% dos pedidos (jul: 3.483
-- de 6.048 creditados, +R$ 9.337 de repasse inflado; ago: 807 de 937, +R$ 4.644).
-- A carteira (ESCROW_VERIFIED_ADD) prova: re-lendo o escrow após a conclusão,
-- o valor bate centavo a centavo com o creditado.
--
-- Fix: cada pedido ganha UMA re-busca do escrow depois que o crédito
-- ESCROW_VERIFIED_ADD aparece na carteira (= conclusão, validado na Fase 0 do
-- ciclo de vida: ±5min em 99,40%). Marcador escrow_refetch_em evita loop
-- infinito (pedido ajustado APÓS a verificação diverge para sempre da carteira
-- — categoria ADJUSTMENT_*, tratada à parte).
--
-- shopee_fill_ams fica obsoleta (só olha ams IS NULL; após a 1ª foto o valor
-- é 0, não NULL — por isso ela "se aposentou sozinha" em 11/07).
-- =============================================================================

-- 1. Marcador da re-busca final
ALTER TABLE shopee_pedidos
  ADD COLUMN IF NOT EXISTS escrow_refetch_em timestamptz;

COMMENT ON COLUMN shopee_pedidos.escrow_refetch_em IS
  'Quando o escrow foi relido após a conclusão (ESCROW_VERIFIED_ADD na carteira). NULL = re-busca pendente. Fix 18/08/2026: AMS/afiliados só existe no escrow perto da conclusão.';

-- 2. Seeds — o que NÃO precisa de re-busca via API:
-- (a) pré-10/07: ams veio do backfill de 09-10/07, que leu pedidos JÁ
--     concluídos — a foto é final por construção (jun: 465 pedidos com AMS).
UPDATE shopee_pedidos
SET escrow_refetch_em = clock_timestamp()
WHERE escrow_refetch_em IS NULL
  AND create_time < '2026-07-10 00:00:00-03';

-- (b) janela quebrada, mas 1ª foto == crédito da carteira: comprovadamente
--     final (AMS teria REDUZIDO o escrow; se não mudou, não houve afiliado).
UPDATE shopee_pedidos p
SET escrow_refetch_em = clock_timestamp()
FROM (
  SELECT order_sn, sum(amount) AS creditado
  FROM shopee_wallet
  WHERE transaction_type = 'ESCROW_VERIFIED_ADD'
  GROUP BY 1
) c
WHERE c.order_sn = p.order_sn
  AND p.escrow_refetch_em IS NULL
  AND p.escrow_adjusted IS NOT NULL
  AND abs(p.escrow_adjusted - c.creditado) <= 0.01;

-- 3. Re-busca: mesma escrita do shopee_fill_escrow, seleção = creditado na
--    carteira + ainda sem re-busca + já teve 1ª foto (sem foto é papel do
--    fill_escrow; a re-busca espera).
CREATE OR REPLACE FUNCTION public.shopee_refetch_escrow(p_limit integer DEFAULT 100)
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
    SELECT p.order_sn FROM shopee_pedidos p
    WHERE p.escrow_refetch_em IS NULL
      AND p.escrow_amount IS NOT NULL
      AND EXISTS (SELECT 1 FROM shopee_wallet w
                  WHERE w.order_sn = p.order_sn
                    AND w.transaction_type = 'ESCROW_VERIFIED_ADD')
    ORDER BY p.create_time
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    v_resp := _sp_api_get('/api/v2/payment/get_escrow_detail', 'order_sn=' || v_sn, v_pid, v_pkey, v_access, v_shop_id);
    v_income := v_resp->'response'->'order_income';
    IF v_income IS NOT NULL THEN
      UPDATE shopee_pedidos SET
        net_commission  = (v_income->>'net_commission_fee')::numeric,
        net_service_fee = (v_income->>'net_service_fee')::numeric,
        shipping_fee    = (v_income->>'actual_shipping_fee')::numeric,
        escrow_amount   = (v_income->>'escrow_amount')::numeric,
        escrow_adjusted = (v_income->>'escrow_amount_after_adjustment')::numeric,
        buyer_total     = (v_income->>'buyer_total_amount')::numeric,
        ams_commission  = COALESCE((v_income->>'order_ams_commission_fee')::numeric, 0),
        escrow_refetch_em = clock_timestamp()
      WHERE order_sn = v_sn;
      v_done := v_done + 1;
    ELSE
      -- falha fica NULL e re-tenta na próxima passada (padrão do fill_escrow)
      v_failed := v_failed + 1;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO v_remaining FROM shopee_pedidos p
  WHERE p.escrow_refetch_em IS NULL
    AND p.escrow_amount IS NOT NULL
    AND EXISTS (SELECT 1 FROM shopee_wallet w
                WHERE w.order_sn = p.order_sn
                  AND w.transaction_type = 'ESCROW_VERIFIED_ADD');

  IF v_done > 0 OR v_failed > 0 THEN
    INSERT INTO oauth_refresh_log(conta, http_status, success, message)
    VALUES ('shopee_refetch', 200, v_failed = 0,
            'done=' || v_done || ' failed=' || v_failed || ' remaining=' || v_remaining);
  END IF;
  RETURN jsonb_build_object('processed', v_done, 'failed', v_failed, 'remaining', v_remaining);
END $function$;

-- 4. Loop chunked (mesmo padrão do shopee_escrow_fill_loop), lock próprio
CREATE OR REPLACE FUNCTION public.shopee_refetch_escrow_loop()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_r jsonb; v_done int:=0; v_rem int:=0; v_iter int:=0; v_ini timestamptz:=clock_timestamp();
BEGIN
  IF NOT pg_try_advisory_lock(421982812) THEN RETURN jsonb_build_object('skipped','already_running'); END IF;
  LOOP
    v_r := shopee_refetch_escrow(100);
    v_done := v_done + coalesce((v_r->>'processed')::int,0);
    v_rem := coalesce((v_r->>'remaining')::int,0);
    v_iter := v_iter + 1;
    EXIT WHEN v_rem=0 OR coalesce((v_r->>'processed')::int,0)=0 OR v_iter>=6
          OR clock_timestamp()-v_ini > interval '240 seconds';
  END LOOP;
  PERFORM pg_advisory_unlock(421982812);
  RETURN jsonb_build_object('processed',v_done,'remaining',v_rem,'iters',v_iter);
END $function$;

REVOKE ALL ON FUNCTION public.shopee_refetch_escrow(int)    FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.shopee_refetch_escrow_loop()  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopee_refetch_escrow(int)   TO service_role;
GRANT EXECUTE ON FUNCTION public.shopee_refetch_escrow_loop() TO service_role;

-- 5. Crons de escrow passam a rodar a re-busca depois do fill (12:00 e 18:00
--    BRT — ambos DEPOIS de uma passada da carteira, 04:30/13:10, que é quem
--    revela as conclusões novas). cron.schedule com mesmo nome = upsert.
SELECT cron.schedule('shopee-escrow-meiodia', '0 15 * * *',
  $cmd$SET statement_timeout='600s'; SELECT public.shopee_escrow_fill_loop(); SELECT public.shopee_refetch_escrow_loop();$cmd$);
SELECT cron.schedule('shopee-escrow-tarde', '0 21 * * *',
  $cmd$SET statement_timeout='600s'; SELECT public.shopee_escrow_fill_loop(); SELECT public.shopee_refetch_escrow_loop();$cmd$);

COMMENT ON FUNCTION public.shopee_fill_ams(int) IS
  'OBSOLETA desde 18/08/2026 — só processa ams_commission IS NULL, e a 1ª foto do escrow grava 0 (não NULL). Substituída por shopee_refetch_escrow (re-busca pós-conclusão).';
