-- =============================================================================
-- Shopee: reconferência de pedidos UNPAID (status congelado na inserção)
-- 19/08/2026
--
-- Problema: as fases 1+2 do cron só INSEREM pedido novo (ON CONFLICT DO NOTHING)
-- e nenhum fluxo atualizava o status de quem nasceu UNPAID e foi pago depois
-- (pix/boleto com lag). Medido em 19/08: 190 pedidos UNPAID na tabela, dos quais
-- 27 JÁ TINHAM crédito ESCROW_VERIFIED_ADD na carteira — R$ 4.056,33 fora da
-- bruta e sem escrow (a régua e o fill_escrow excluem UNPAID), desde 13/07.
-- shopee_reconfere_status não cobre: só flipa para CANCELLED.
--
-- Fix: re-checar os UNPAID recentes via get_order_detail (lotes de 50) e
-- atualizar order_status + pay_time. Pago vira elegível ao fill_escrow no mesmo
-- ciclo; concluído entra na re-busca pós-conclusão (20260818150001).
-- Roda nos jobs shopee-ciclo / shopee-ciclo-tarde (05:00 / 13:40 BRT).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.shopee_reconfere_unpaid(p_dias integer DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_sns text[]; v_batch text[]; v_detail jsonb; v_order jsonb;
  v_i int; v_novo text;
  v_verificados int := 0; v_atualizados int := 0; v_pagos int := 0; v_cancelados int := 0;
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

  SELECT array_agg(order_sn) INTO v_sns
  FROM shopee_pedidos
  WHERE order_status = 'UNPAID'
    AND create_time > clock_timestamp() - (p_dias || ' days')::interval;

  IF v_sns IS NULL THEN
    RETURN jsonb_build_object('verificados', 0, 'atualizados', 0);
  END IF;

  v_i := 1;
  WHILE v_i <= array_length(v_sns, 1) LOOP
    v_batch := v_sns[v_i : LEAST(v_i + 49, array_length(v_sns, 1))];
    v_detail := _sp_api_get('/api/v2/order/get_order_detail',
      'order_sn_list=' || array_to_string(v_batch, ','),
      v_pid, v_pkey, v_access, v_shop_id);
    IF v_detail->'response'->'order_list' IS NOT NULL THEN
      FOR v_order IN SELECT value FROM jsonb_array_elements(v_detail->'response'->'order_list') LOOP
        v_verificados := v_verificados + 1;
        v_novo := v_order->>'order_status';
        IF v_novo IS NOT NULL AND v_novo <> 'UNPAID' THEN
          UPDATE shopee_pedidos SET
            order_status = v_novo,
            pay_time = COALESCE(
              CASE WHEN (v_order->>'pay_time')::bigint > 0 THEN to_timestamp((v_order->>'pay_time')::bigint) END,
              pay_time)
          WHERE order_sn = v_order->>'order_sn';
          v_atualizados := v_atualizados + 1;
          IF v_novo IN ('CANCELLED','IN_CANCEL') THEN v_cancelados := v_cancelados + 1;
          ELSE v_pagos := v_pagos + 1;
          END IF;
        END IF;
      END LOOP;
    END IF;
    v_i := v_i + 50;
  END LOOP;

  IF v_atualizados > 0 THEN
    INSERT INTO oauth_refresh_log(conta, http_status, success, message)
    VALUES ('shopee_unpaid', 200, true,
            'verificados=' || v_verificados || ' virou_pago=' || v_pagos || ' virou_cancelado=' || v_cancelados);
  END IF;

  RETURN jsonb_build_object(
    'verificados', v_verificados, 'atualizados', v_atualizados,
    'virou_pago', v_pagos, 'virou_cancelado', v_cancelados);
END $function$;

REVOKE ALL ON FUNCTION public.shopee_reconfere_unpaid(int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shopee_reconfere_unpaid(int) TO service_role;

-- Jobs de ciclo passam a reconferir os UNPAID (upsert por nome no cron.schedule)
SELECT cron.schedule('shopee-ciclo', '0 8 * * *',
  $cmd$set statement_timeout to '8min'; select public.shopee_fill_ciclo(30, 250); select public.shopee_reconfere_unpaid(60);$cmd$);
SELECT cron.schedule('shopee-ciclo-tarde', '40 16 * * *',
  $cmd$set statement_timeout to '8min'; select public.shopee_fill_ciclo(30, 250); select public.shopee_reconfere_unpaid(60);$cmd$);

-- =============================================================================
-- Correção do seed de 20260818150001: pedidos criados 05→10/07 foram carimbados
-- como "foto final por construção", mas o backfill de ams de 09/07 TAMBÉM leu
-- cedo demais os que ainda estavam em trânsito — 528 pedidos creditados com
-- escrow bruto (sem o desconto de afiliados) e ams_commission=0, R$ 4.364,11 de
-- repasse inflado. Descarimbar = a re-busca pós-conclusão os corrige (todos já
-- têm ESCROW_VERIFIED_ADD; fila drenada pelos jobs de escrow).
-- =============================================================================
UPDATE shopee_pedidos p
SET escrow_refetch_em = NULL
FROM (
  SELECT order_sn, sum(amount) AS creditado
  FROM shopee_wallet
  WHERE transaction_type = 'ESCROW_VERIFIED_ADD'
  GROUP BY 1
) c
WHERE c.order_sn = p.order_sn
  AND p.escrow_refetch_em IS NOT NULL
  AND p.escrow_amount IS NOT NULL
  AND abs(p.escrow_amount - c.creditado) > 0.01;
