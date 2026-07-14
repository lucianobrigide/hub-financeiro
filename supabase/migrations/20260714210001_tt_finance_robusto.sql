-- TIKTOK — finance robusto: destrava julho + robustez no padrao ML.
--
-- O BUG (confirmado ao vivo contra a API): para pedido NAO LIQUIDADO, o finance do TikTok
-- devolve HTTP 200 / code 0 / "Success" com:
--     {"total_count":0, "revenue_amount":"0", "sku_transactions":[], "settlement_amount":"0"}
-- ou seja, "0" e [] — NAO null. O guard antigo so testava `is null`, entao passava direto e
-- gravava fin_filled=true com ZEROS e fin_breakdown NULL. Como a fila e `where fin_filled=false`,
-- o pedido saia PRA SEMPRE. Julho ficou com bruta 0 (9 de 9 travados). Junho escapou por sorte:
-- foi ingerido semanas depois, com quase tudo ja liquidado (pegou so 5 de 117).
--   -> E o MESMO padrao do escrow da Shopee: um gatilho que, uma vez marcado, nunca re-tenta.
--
-- FIX 1 — GUARD: usa `total_count = 0` (campo que a propria API oferece) + sku_transactions
--   vazio. Nao-liquidado NAO marca fin_filled -> fica na fila e re-tenta ate liquidar.
--
-- FIX 2 — TAXONOMIA DE RETRY (a licao dos 3 estados do ML). O fin_attempts<3 so deve matar
--   pedido PERMANENTEMENTE problematico:
--     nao_liquidado (total_count=0) -> NAO consome tentativa (estado normal; o repasse do
--                                     TikTok leva 7-15 dias e o limite de 3 matava antes)
--     429 / 5xx                     -> NAO consome tentativa (transitorio, culpa da API)
--     demais erros (4xx, code<>0)   -> consome tentativa
--   VISTO AO VIVO: o TikTok devolve `http_429 "Too many requests for downstream"` sob carga.
--   A 1a versao deste fix contava 429 como erro real -> 3 rate-limits matariam um pedido bom.
--   Confirmado na pratica: um pedido DELIVERED com finance REAL (revenue 204,90) ja tinha
--   ficado com attempts=1 por 429. Antes o attempts era incrementado ANTES da chamada, sem
--   sequer saber o resultado.
--
-- FIX 3 — LOG HONESTO no tt_cron_diario: `success` era TRUE hardcoded. Agora falha real
--   (fail>0 ou erro do fill) derruba o sucesso. aguardando_liquidar e throttled_429 NAO sao
--   falha -> nao gritam (senao o alerta vira ruido: a licao do cry-wolf do ML).
--
-- FIX 4 — JANELA do diario 3 -> 7 dias: era a mais estreita da casa (ML/Shopee usam 7).
--   Janela curta cria VAO — foi exatamente o que furou a Shopee de 01-06/07.
--   (O tt_cron_semanal continua com 30 dias: esse e o desenho certo p/ reconferencia longa.)
--
-- FIX 5 — tt_saude: o TikTok estava FORA de qualquer alerta (o ml_saude so le ml_cron_log; o
--   TikTok loga em oauth_refresh_log). N=2 dias, e distingue os 3 estados de cobertura:
--     aguardando_liquidar = NORMAL | travados_bug = o bug voltou | mortos = desistiu (erro real)
--
-- DESTRAVAMENTO: 14 pedidos com fin_filled=true e breakdown NULL voltaram pra fila
-- (fin_filled=false, fin_attempts=0). Correcao de DADO, ja aplicada — sem artefato aqui.
--
-- IMPACTO: M.C. junho -R$93,75 -> +R$597,53. O numero validado antes estava sobre DADO
-- INCOMPLETO (5 pedidos travados). A identidade continua fechando ao centavo
-- (liquido - fees - frete = settlement) — era o dado, nao o metodo.
--
-- Definicoes capturadas via pg_get_functiondef (repo == banco).
-- PENDENCIA: tt_cron_semanal ainda tem success=true hardcoded (nao tocado nesta migration).

-- ====== tt_fill_finance — guard de nao-liquidado + taxonomia de retry ======
CREATE OR REPLACE FUNCTION public.tt_fill_finance(p_limit integer DEFAULT 300)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
 SET statement_timeout TO '300s'
AS $function$
declare
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_id text; v_resp jsonb; v_data jsonb; v_bd jsonb; v_rb jsonb; v_err text;
  v_done int := 0; v_empty int := 0; v_fail int := 0; v_throttled int := 0; v_remaining int;
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name='tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name='tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher from public.tt_oauth_state where id=1;
  if v_app_key is null or v_access is null then return jsonb_build_object('error','missing_credentials'); end if;

  if (select expires_at from public.tt_oauth_state where id=1) < clock_timestamp() + interval '15 minutes' then
    perform public.tt_refresh_token(true);
    select access_token into v_access from public.tt_oauth_state where id=1;
  end if;

  for v_id in
    select order_id from public.tt_pedidos
    where fin_filled = false and order_status <> 'CANCELLED' and fin_attempts < 3
    order by create_time limit p_limit
  loop
    v_resp := public._tt_get('/finance/202501/orders/'||v_id||'/statement_transactions',
      '{}'::jsonb, v_app_key, v_app_secret, v_access, v_cipher);
    v_err := coalesce(v_resp->>'error','');

    -- TRANSITÓRIO (429/5xx): a API pediu pra esperar. NÃO consome tentativa.
    if v_err in ('http_429','http_500','http_502','http_503','http_504')
       or coalesce((v_resp->>'code')::bigint, 0) = 36009002 then
      v_throttled := v_throttled + 1; continue;
    end if;

    -- ERRO REAL do pedido: consome tentativa (o <3 evita insistir eternamente).
    if v_err <> '' or coalesce((v_resp->>'code')::int, -1) <> 0 then
      update public.tt_pedidos set fin_attempts = fin_attempts + 1 where order_id = v_id;
      v_fail := v_fail + 1; continue;
    end if;

    v_data := v_resp->'data';

    -- NÃO LIQUIDADO (estado normal): NÃO consome tentativa -> re-tenta amanhã, até liquidar.
    if v_data is null
       or coalesce((v_data->>'total_count')::int, 0) = 0
       or jsonb_array_length(coalesce(v_data->'sku_transactions','[]'::jsonb)) = 0
       or v_data->>'revenue_amount' is null then
      v_empty := v_empty + 1; continue;
    end if;

    select jsonb_object_agg(k, s) into v_bd from (
      select kv.key k, sum(kv.value::numeric) s
      from jsonb_array_elements(v_data->'sku_transactions') st,
           lateral (
             select * from jsonb_each_text(coalesce(st->'fee_tax_breakdown'->'fee','{}'::jsonb))
             union all
             select * from jsonb_each_text(coalesce(st->'fee_tax_breakdown'->'tax','{}'::jsonb))
           ) kv
      group by kv.key
    ) t;

    select jsonb_object_agg(k, s) into v_rb from (
      select kv.key k, sum(kv.value::numeric) s
      from jsonb_array_elements(v_data->'sku_transactions') st,
           lateral jsonb_each_text(coalesce(st->'revenue_breakdown','{}'::jsonb)) kv
      group by kv.key
    ) t;

    update public.tt_pedidos set
      fin_filled        = true,
      fin_revenue       = nullif(v_data->>'revenue_amount','')::numeric,
      fin_settlement    = nullif(v_data->>'settlement_amount','')::numeric,
      fin_frete         = nullif(v_data->>'shipping_cost_amount','')::numeric,
      fin_fee_tax       = nullif(v_data->>'fee_and_tax_amount','')::numeric,
      fin_commission    = coalesce((v_bd->>'platform_commission_amount')::numeric, 0),
      fin_breakdown     = v_bd,
      fin_rev_breakdown = v_rb
    where order_id = v_id;
    v_done := v_done + 1;
  end loop;

  select count(*) into v_remaining from public.tt_pedidos
    where fin_filled=false and order_status<>'CANCELLED' and fin_attempts<3;

  return jsonb_build_object(
    'done', v_done,
    'aguardando_liquidar', v_empty,   -- normal (não consome tentativa)
    'throttled_429', v_throttled,     -- rate limit (não consome tentativa)
    'fail', v_fail,                   -- erro real do pedido (consome tentativa)
    'remaining', v_remaining);
end $function$;

-- ====== tt_cron_diario — log honesto + janela 3->7d ======
CREATE OR REPLACE FUNCTION public.tt_cron_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
DECLARE
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_ge bigint; v_lt bigint; v_body text;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_token text := ''; v_more boolean := true;
  v_order jsonb; v_item jsonb;
  v_orders int := 0; v_items int := 0; v_pages int := 0;
  v_fin jsonb;
BEGIN
  IF NOT pg_try_advisory_lock(421982737) THEN
    RETURN jsonb_build_object('skipped','already_running');
  END IF;
  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_access IS NULL THEN
    PERFORM pg_advisory_unlock(421982737);
    RETURN jsonb_build_object('error','missing_credentials');
  END IF;
  IF (SELECT expires_at FROM public.tt_oauth_state WHERE id=1) < clock_timestamp() + interval '30 minutes' THEN
    PERFORM public.tt_refresh_token(true);
    SELECT access_token INTO v_access FROM public.tt_oauth_state WHERE id=1;
  END IF;
  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '7 days';  -- 3->7: alinha com ML/Shopee (janela curta cria vao)
  v_ge := extract(epoch from v_win_start)::bigint;
  v_lt := extract(epoch from v_win_end)::bigint;
  v_body := json_build_object('create_time_ge',v_ge,'create_time_lt',v_lt)::text;
  WHILE v_more LOOP
    v_resp := public._tt_post('/order/202309/orders/search',
      jsonb_build_object('page_size','100') || CASE WHEN v_token<>'' THEN jsonb_build_object('page_token',v_token) ELSE '{}'::jsonb END,
      v_body, v_app_key, v_app_secret, v_access, v_cipher);
    IF v_resp->>'error' IS NOT NULL OR (v_resp->>'code')::int <> 0 THEN
      PERFORM pg_advisory_unlock(421982737);
      RETURN jsonb_build_object('error',coalesce(v_resp->>'error','api_'||(v_resp->>'code')),'message',v_resp->>'message');
    END IF;
    v_pages := v_pages + 1;
    FOR v_order IN SELECT value FROM jsonb_array_elements(coalesce(v_resp->'data'->'orders','[]'::jsonb)) LOOP
      INSERT INTO public.tt_pedidos (order_id, create_time, order_status, currency, payment_total)
      VALUES (v_order->>'id', to_timestamp((v_order->>'create_time')::bigint), v_order->>'status',
              v_order->'payment'->>'currency', nullif(v_order->'payment'->>'total_amount','')::numeric)
      ON CONFLICT (order_id) DO UPDATE
        SET order_status=excluded.order_status, payment_total=excluded.payment_total;
      v_orders := v_orders + 1;
      FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_order->'line_items','[]'::jsonb)) LOOP
        INSERT INTO public.tt_itens (order_id, line_item_id, seller_sku, sku_id, product_name, line_status, sale_price, original_price, seller_discount, quantity)
        VALUES (v_order->>'id', v_item->>'id', v_item->>'seller_sku', v_item->>'sku_id', v_item->>'product_name',
                v_item->>'display_status', nullif(v_item->>'sale_price','')::numeric,
                nullif(v_item->>'original_price','')::numeric, nullif(v_item->>'seller_discount','')::numeric, 1)
        ON CONFLICT (order_id, line_item_id) DO UPDATE SET line_status=excluded.line_status;
        v_items := v_items + 1;
      END LOOP;
    END LOOP;
    v_token := coalesce(v_resp->'data'->>'next_page_token','');
    v_more := v_token <> '';
  END LOOP;
  v_fin := public.tt_fill_finance(200);
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('tt_cron', 200,
    coalesce((v_fin->>'fail')::int, 0) = 0 and (v_fin->>'error') is null,
    case when (v_fin->>'error') is not null then 'FALHA no finance: '||(v_fin->>'error')
         when coalesce((v_fin->>'fail')::int,0) > 0 then (v_fin->>'fail')||' pedidos com ERRO real no finance'
         else 'ok' end
    ||' | janela='||to_char(v_win_start,'YYYY-MM-DD')||'..'||to_char(v_win_end,'YYYY-MM-DD')
    ||' pedidos='||v_orders||' itens='||v_items||' pages='||v_pages
    ||' fin_done='||coalesce(v_fin->>'done','0')
    ||' aguardando_liquidar='||coalesce(v_fin->>'aguardando_liquidar','0')
    ||' throttled_429='||coalesce(v_fin->>'throttled_429','0')
    ||' fin_fail='||coalesce(v_fin->>'fail','0')
    ||' fin_remaining='||coalesce(v_fin->>'remaining','0'));
  PERFORM pg_advisory_unlock(421982737);
  RETURN jsonb_build_object('janela_ini',v_win_start,'janela_fim',v_win_end,
    'pedidos_na_janela',v_orders,'itens',v_items,'pages',v_pages,'finance',v_fin);
END $function$;

-- ====== tt_saude — alerta N=2 + cobertura em 3 estados ======
CREATE OR REPLACE FUNCTION public.tt_saude(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with runs as (
    select distinct on ((created_at at time zone 'America/Sao_Paulo')::date)
           (created_at at time zone 'America/Sao_Paulo')::date as dia,
           coalesce(success,false) as sucesso, message
    from public.oauth_refresh_log
    where conta = 'tt_cron' and created_at > now() - interval '10 days'
    order by (created_at at time zone 'America/Sao_Paulo')::date, created_at desc
  ),
  falhas as (
    select max(dia) filter (where sucesso) as ultimo_ok,
           count(*) filter (where not sucesso) as dias_com_falha,
           (array_agg(message order by dia desc) filter (where not sucesso))[1] as ultimo_erro
    from runs
  ),
  mes as (
    select
      count(*) filter (where order_status <> 'CANCELLED') as nao_canc,
      count(*) filter (where order_status <> 'CANCELLED' and fin_filled and fin_breakdown is not null) as com_finance_real,
      count(*) filter (where order_status <> 'CANCELLED' and not fin_filled and fin_attempts < 3) as aguardando_liquidar,
      count(*) filter (where order_status <> 'CANCELLED' and fin_filled and fin_breakdown is null) as travados_bug,
      count(*) filter (where order_status <> 'CANCELLED' and not fin_filled and fin_attempts >= 3) as mortos_desistiu
    from public.tt_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM') = p_month
  )
  select jsonb_build_object(
    'mes', p_month,
    'cobertura', (select jsonb_build_object(
        'nao_cancelados', nao_canc,
        'com_finance_real', com_finance_real,
        'aguardando_liquidar', aguardando_liquidar,   -- normal
        'travados_bug', travados_bug,                 -- deve ser 0
        'mortos_desistiu', mortos_desistiu,           -- deve ser 0
        'pct_com_finance', case when nao_canc>0 then round(100.0*com_finance_real/nao_canc,1) else null end
      ) from mes),
    'alerta_cron_falhando', (select case when coalesce(
        ((now() at time zone 'America/Sao_Paulo')::date - ultimo_ok), dias_com_falha) >= 2
        and dias_com_falha > 0
      then jsonb_build_object('dias_seguidos',
             coalesce(((now() at time zone 'America/Sao_Paulo')::date - ultimo_ok), dias_com_falha),
             'ultimo_ok', ultimo_ok, 'erro', ultimo_erro)
      else null end from falhas),
    'alerta_travados', (select case when travados_bug > 0
      then jsonb_build_object('n', travados_bug, 'obs', 'fin_filled=true sem breakdown: o bug do guard voltou')
      else null end from mes),
    'tem_alerta', (select (coalesce(((now() at time zone 'America/Sao_Paulo')::date - ultimo_ok), dias_com_falha) >= 2
                           and dias_com_falha > 0) from falhas)
                  or (select travados_bug > 0 or mortos_desistiu > 0 from mes)
  );
$function$;
