-- Cron ml-ads-item (ml_fill_ads_item) falhava com "ON CONFLICT DO UPDATE command cannot affect
-- row a second time" quando o mesmo item_id vinha em mais de uma linha no dia (item anunciado em
-- campanhas/ads diferentes) — o INSERT gerava (data,item_id) duplicado no mesmo comando.
-- Fix: agrupar por item_id somando o custo antes do upsert. (Luciano, 24/07/2026.)
-- Só o bloco INSERT..SELECT mudou (agora com subquery + GROUP BY item_id + SUM(cost)).

CREATE OR REPLACE FUNCTION public.ml_fill_ads_item(p_month text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'extensions' SET statement_timeout TO '300s'
AS $function$
DECLARE
  v_tok text; v_adv text; v_resp jsonb; v_dia date; v_hoje date;
  v_dias int := 0; v_linhas int := 0; v_erro text := NULL;
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN RETURN jsonb_build_object('ok',false,'erro','sem_token'); END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','60000');

  SELECT (c.content::jsonb->'advertisers'->0->>'advertiser_id') INTO v_adv
  FROM extensions.http((
    'GET','https://api.mercadolibre.com/advertising/advertisers?product_id=PADS',
    ARRAY[extensions.http_header('Authorization','Bearer '||v_tok), extensions.http_header('Api-Version','1')],
    NULL, NULL)::extensions.http_request) c;
  IF v_adv IS NULL THEN RETURN jsonb_build_object('ok',false,'erro','sem_advertiser'); END IF;

  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  FOR v_dia IN
    SELECT d::date FROM generate_series((p_month||'-01')::date,
      (date_trunc('month',(p_month||'-01')::date)+interval '1 month' - interval '1 day')::date, '1 day') d
  LOOP
    EXIT WHEN v_dia >= v_hoje;  -- só dias completos
    BEGIN
      SELECT c.content::jsonb INTO v_resp FROM extensions.http((
        'GET',
        'https://api.mercadolibre.com/advertising/MLB/advertisers/'||v_adv||
        '/product_ads/ads/search?limit=500&offset=0&date_from='||v_dia||'&date_to='||v_dia||'&metrics=cost',
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok), extensions.http_header('api-version','2')],
        NULL, NULL)::extensions.http_request) c;
    EXCEPTION WHEN OTHERS THEN v_resp := NULL; v_erro := SQLERRM; END;
    IF v_resp IS NULL THEN CONTINUE; END IF;

    -- dedup: mesmo item_id pode vir em várias linhas no dia -> soma antes do upsert
    INSERT INTO public.ml_ads_item_diario(data, item_id, gasto)
    SELECT v_dia, item_id, round(sum(cost),2)
    FROM (
      SELECT e->>'item_id' AS item_id, coalesce((e->'metrics'->>'cost')::numeric,0) AS cost
      FROM jsonb_array_elements(v_resp->'results') e
    ) x
    WHERE item_id IS NOT NULL
    GROUP BY item_id
    HAVING round(sum(cost),2) > 0
    ON CONFLICT (data, item_id) DO UPDATE SET gasto=excluded.gasto, atualizado_em=now();
    GET DIAGNOSTICS v_linhas = ROW_COUNT;
    v_dias := v_dias + 1;
    PERFORM pg_sleep(0.15);
  END LOOP;

  RETURN jsonb_build_object('ok',true,'advertiser',v_adv,'dias',v_dias,'erro',v_erro,
    'no_banco',(SELECT count(*) FROM public.ml_ads_item_diario WHERE to_char(data,'YYYY-MM')=p_month));
END $function$;
