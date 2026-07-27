-- ADS Shopee: a FASE 4 do shopee_cron_diario (03:30) captura o mês corrente, mas sem retry —
-- quando a API de ADS falha/volta vazia no horário (transitório), retorna ads_dias=0 e não grava
-- nada; o dia fica parado no parcial capturado no próprio dia (ex.: 26/07 travou em R$55 em vez
-- de R$1.343). Igual ao padrão do ML (ml-ads-reconferir). (Luciano, 27/07/2026.)
-- Fix: cron de RECONFERÊNCIA do ADS ao meio-dia e à tarde, com retry, re-puxando mês corrente+anterior.
-- shopee_fill_ads é idempotente (upsert por data), então re-rodar só refresca pro valor final.

CREATE OR REPLACE FUNCTION public.shopee_ads_reconferir() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions' SET statement_timeout TO '150s'
AS $function$
DECLARE v_today date; v_cur jsonb; v_prev jsonb; v_try int := 0;
BEGIN
  v_today := (now() at time zone 'America/Sao_Paulo')::date;
  LOOP
    v_try := v_try + 1;
    v_cur := public.shopee_fill_ads(date_trunc('month', v_today)::date, v_today);
    EXIT WHEN coalesce((v_cur->>'dias')::int,0) > 0 OR v_try >= 4;
    PERFORM pg_sleep(8);
  END LOOP;
  v_prev := public.shopee_fill_ads(date_trunc('month', v_today - interval '1 month')::date, (date_trunc('month', v_today)::date - 1));
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('shopee_ads_reconf', 200, coalesce((v_cur->>'dias')::int,0) > 0,
    'tries='||v_try||' cur_dias='||coalesce(v_cur->>'dias','0')||' cur_exp='||coalesce(v_cur->>'expense_total','0')
    ||coalesce(' err='||(v_cur->>'error'),''));
  RETURN jsonb_build_object('cur', v_cur, 'prev', v_prev, 'tries', v_try);
END $function$;

SELECT cron.schedule('shopee-ads-reconferir-meiodia','0 15 * * *', $$select public.shopee_ads_reconferir()$$);
SELECT cron.schedule('shopee-ads-reconferir-tarde','0 21 * * *', $$select public.shopee_ads_reconferir()$$);
