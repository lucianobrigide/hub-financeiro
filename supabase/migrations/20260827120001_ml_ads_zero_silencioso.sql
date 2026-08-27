-- ADS ML — defesa contra o "zero silencioso" do agregado por campanha (achado 27/08/2026).
--
-- Fato medido: o endpoint campaigns/search (agregado DAILY, api-version 2) passou a devolver
-- HTTP 200 com cost=0.0 para D-1 — a consolidação agora leva ~2 dias (o valor de 25/08 só
-- apareceu na reconferência de 27/08 06:00; em 26/08 o card ficou o dia todo sem ADS do ML).
-- Já o endpoint POR ITEM (ads/search, mesmo advertiser) tem o custo de D-1 já às 03:25 e é
-- IGUAL ao agregado consolidado: diff R$ 0,00 em 22 dias seguidos (04..25/08/2026);
-- 01-03/08 diff < R$ 39 com o item MAIOR (conservador a favor da M.C. menor).
--
-- Duas defesas (nada estimado — tudo dado real da API, REGRA DURA preservada):
-- 1) ml_upsert_ads não sobrescreve mais gasto > 0 com 0: o zero silencioso da API não
--    regride um valor real já capturado. Inserir dia novo com 0 continua permitido
--    (cobertura honesta), e correção para qualquer valor > 0 continua passando.
-- 2) ml_fill_ads_item (cron ml-ads-item, 03:25 BRT), após preencher a tabela por item,
--    faz FALLBACK: para todo dia do mês com soma por item > 0 e product_ads (campanha)
--    ausente/zerado, grava a soma por item em ml_ads_diario. Quando o ML consolida o
--    agregado (~D+2), a reconferência das 06:00 substitui pelo valor oficial (> 0 passa
--    pela guarda). brand_ads (~R$ 150-250/dia) não tem fonte por item — segue aparecendo
--    só quando o ML consolida.

create or replace function public.ml_upsert_ads(p_rows jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n integer;
begin
  insert into public.ml_ads_diario (data, produto, gasto)
  select r.data, r.produto, r.gasto
  from jsonb_to_recordset(p_rows) as r(data date, produto text, gasto numeric)
  on conflict (data, produto) do update
    set gasto = excluded.gasto, atualizado_em = now()
    -- zero silencioso: nunca regride valor real (>0) para 0
    where excluded.gasto > 0 or ml_ads_diario.gasto = 0;
  get diagnostics n = row_count; return n;
end $function$;

create or replace function public.ml_fill_ads_item(p_month text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
 set statement_timeout to '300s'
as $function$
DECLARE
  v_tok text; v_adv text; v_resp jsonb; v_dia date; v_hoje date;
  v_dias int := 0; v_linhas int := 0; v_fallback int := 0; v_erro text := NULL;
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN RETURN jsonb_build_object('ok',false,'erro','sem_token'); END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','60000');

  SELECT (c.content::jsonb->'advertisers'->0->>'advertiser_id') INTO v_adv
  FROM extensions.http(('GET',
    'https://api.mercadolibre.com/advertising/advertisers?product_id=PADS',
    ARRAY[extensions.http_header('Authorization','Bearer '||v_tok), extensions.http_header('Api-Version','1')],
    NULL, NULL)::extensions.http_request) c;
  IF v_adv IS NULL THEN RETURN jsonb_build_object('ok',false,'erro','sem_advertiser'); END IF;

  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  FOR v_dia IN
    SELECT d::date FROM generate_series((p_month||'-01')::date,
      (date_trunc('month',(p_month||'-01')::date)+interval '1 month' - interval '1 day')::date, '1 day') d
  LOOP
    EXIT WHEN v_dia >= v_hoje;
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

  -- FALLBACK zero silencioso: dia com custo real por item mas agregado por campanha
  -- zerado/ausente (a API demora ~2 dias pra consolidar o DAILY) -> usa a soma por item,
  -- que é igual ao agregado consolidado (diff 0,00 em 22 dias medidos). A reconferência
  -- substitui pelo oficial quando ele chegar (>0 passa pela guarda do ml_upsert_ads).
  INSERT INTO public.ml_ads_diario (data, produto, gasto)
  SELECT i.data, 'product_ads', i.gasto
  FROM (
    SELECT data, round(sum(gasto),2) AS gasto
    FROM public.ml_ads_item_diario
    WHERE to_char(data,'YYYY-MM') = p_month
    GROUP BY data
  ) i
  LEFT JOIN public.ml_ads_diario a ON a.data = i.data AND a.produto = 'product_ads'
  WHERE i.gasto > 0 AND coalesce(a.gasto, 0) = 0
  ON CONFLICT (data, produto) DO UPDATE SET gasto = excluded.gasto, atualizado_em = now();
  GET DIAGNOSTICS v_fallback = ROW_COUNT;

  RETURN jsonb_build_object('ok',true,'advertiser',v_adv,'dias',v_dias,'erro',v_erro,
    'fallback_campanha',v_fallback,
    'no_banco',(SELECT count(*) FROM public.ml_ads_item_diario WHERE to_char(data,'YYYY-MM')=p_month));
END $function$;
