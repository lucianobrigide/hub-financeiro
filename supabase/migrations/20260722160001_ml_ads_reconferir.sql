-- ============================================================
-- ML ADS: reconferência dos últimos N dias (corrige captura parcial das 03:00)
-- Problema: ml_cron_diario busca ADS de D-1 às 03:00, mas o ML ainda não
-- consolidou o custo (brand_ads=0, product_ads às vezes 0/preliminar). A
-- reconferência de 7 dias do cron só refaz PEDIDOS, não ADS → valor congela parcial.
-- Solução: job dedicado que re-busca product_ads+brand_ads dos últimos 5 dias,
-- idempotente (ml_edge_call modo=ads faz upsert em ml_ads_diario). Roda 06:00 BRT,
-- depois do ML consolidar mais. Janela rolante garante correção em poucos dias.
-- ============================================================

CREATE OR REPLACE FUNCTION public.ml_reconferir_ads(p_dias int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','vault'
AS $$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  d date; i int; v_res jsonb; v_ok int := 0; v_falhas int := 0;
BEGIN
  FOR i IN 0..(p_dias-1) LOOP
    d := v_ontem - i;
    v_res := ml_edge_call(jsonb_build_object('modo','ads','dia', d::text));
    IF (v_res->>'http_status') = '200' THEN v_ok := v_ok + 1; ELSE v_falhas := v_falhas + 1; END IF;
    PERFORM pg_sleep(0.2);  -- respeita rate limit da API de Ads
  END LOOP;
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, mensagem)
  VALUES ('ads_reconferir', v_ontem, v_falhas = 0,
    'dias='||p_dias||' ok='||v_ok||' falhas='||v_falhas||' janela='||(v_ontem-(p_dias-1))||'..'||v_ontem);
  RETURN jsonb_build_object('dias',p_dias,'ok',v_ok,'falhas',v_falhas,'de',v_ontem-(p_dias-1),'ate',v_ontem);
END $$;

REVOKE ALL ON FUNCTION public.ml_reconferir_ads(int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ml_reconferir_ads(int) TO service_role;

-- Cron: 06:00 BRT (09:00 UTC), após o ml-diario (03:00). Reconfere últimos 5 dias de ADS.
SELECT cron.schedule('ml-ads-reconferir','0 9 * * *',
  $$SET statement_timeout='120s'; SELECT public.ml_reconferir_ads(5)$$);
