-- Fix durável do lag de escrow do ÚLTIMO DIA na Shopee.
--
-- Sintoma recorrente: a M.C. da Shopee do mês corrente aparece negativa porque os pedidos
-- do dia mais recente não têm escrow buscado — logo a retenção é modelada como ~100%.
-- Causa: o cron diário roda às 03:30 BRT, mas a Shopee ainda não calculou o income desses
-- pedidos (criados tarde no dia anterior). O loop do cron sai em processed=0 e só tenta de
-- novo no dia seguinte 03:30 → a M.C. fica errada o dia inteiro.
--
-- Fix: duas passadas EXTRAS de escrow durante o dia (12:00 e 18:00 BRT), que drenam os
-- pedidos novos assim que a Shopee libera o income. Reusa shopee_fill_escrow (predicado
-- escrow_amount IS NULL, newest-first) e sai cedo quando não há mais nunca-buscados.
CREATE OR REPLACE FUNCTION public.shopee_escrow_fill_loop()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions' AS $function$
DECLARE v_esc jsonb; v_done int:=0; v_rem int:=0; v_iter int:=0; v_ini timestamptz:=clock_timestamp();
BEGIN
  IF NOT pg_try_advisory_lock(421982799) THEN RETURN jsonb_build_object('skipped','already_running'); END IF;
  LOOP
    v_esc := shopee_fill_escrow(100);
    v_done := v_done + coalesce((v_esc->>'processed')::int,0);
    v_rem := coalesce((v_esc->>'remaining')::int,0);
    v_iter := v_iter + 1;
    EXIT WHEN v_rem=0 OR coalesce((v_esc->>'processed')::int,0)=0 OR v_iter>=8
          OR clock_timestamp()-v_ini > interval '300 seconds';
  END LOOP;
  PERFORM pg_advisory_unlock(421982799);
  IF v_done>0 THEN
    INSERT INTO oauth_refresh_log(conta,http_status,success,message)
    VALUES('shopee_escrow_loop',200,true,'done='||v_done||' remaining='||v_rem||' iters='||v_iter);
  END IF;
  RETURN jsonb_build_object('processed',v_done,'remaining',v_rem,'iters',v_iter);
END $function$;
GRANT EXECUTE ON FUNCTION public.shopee_escrow_fill_loop() TO service_role;

-- 12:00 e 18:00 BRT (15 e 21 UTC). cron.schedule é idempotente por nome (atualiza se existir).
SELECT cron.schedule('shopee-escrow-meiodia', '0 15 * * *', $$SET statement_timeout='600s'; SELECT public.shopee_escrow_fill_loop()$$);
SELECT cron.schedule('shopee-escrow-tarde',   '0 21 * * *', $$SET statement_timeout='600s'; SELECT public.shopee_escrow_fill_loop()$$);
