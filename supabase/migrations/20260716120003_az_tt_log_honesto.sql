-- LOG HONESTO em az-confirmar, az-semanal e tt-semanal (últimos success=true hardcoded).
--
-- Denunciados pela página de Crons como "log não confiável": logavam sucesso=true FIXO, então
-- uma falha sumia e o alerta nunca disparava — a mesma classe do ml_afiliados que ficou 4 dias
-- quebrado dizendo 'ok'. Correção idêntica à do ML/TikTok-diário: o sucesso reflete o resultado.
--   az-confirmar / az-semanal: sucesso = (v_res2->>'http_status')='200'.
--   tt-semanal: sucesso = fail=0 e sem erro no fill_finance; aguardando_liquidar e throttled_429
--               NÃO são falha (transitório/normal) -> não gritam (evita cry-wolf).
-- (O passo 'az-diario'/fechar do az_cron_diario já era honesto — não foi tocado.)
-- Testado nos 4 cenários. Capturado via pg_get_functiondef (repo == banco).

-- ====== tt_cron_semanal ======
CREATE OR REPLACE FUNCTION public.tt_cron_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_ge bigint; v_lt bigint; v_body text;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_token text := ''; v_more boolean := true;
  v_order jsonb; v_item jsonb;
  v_orders int := 0; v_items int := 0; v_pages int := 0; v_fin jsonb;
begin
  if not pg_try_advisory_lock(421982737) then
    return jsonb_build_object('skipped','already_running');
  end if;
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name='tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name='tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher from public.tt_oauth_state where id=1;
  if v_app_key is null or v_access is null then
    perform pg_advisory_unlock(421982737); return jsonb_build_object('error','missing_credentials');
  end if;
  if (select expires_at from public.tt_oauth_state where id=1) < clock_timestamp() + interval '30 minutes' then
    perform public.tt_refresh_token(true);
    select access_token into v_access from public.tt_oauth_state where id=1;
  end if;
  v_win_end   := date_trunc('day', clock_timestamp() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '30 days';
  v_ge := extract(epoch from v_win_start)::bigint;
  v_lt := extract(epoch from v_win_end)::bigint;
  v_body := json_build_object('create_time_ge',v_ge,'create_time_lt',v_lt)::text;
  while v_more loop
    v_resp := public._tt_post('/order/202309/orders/search',
      jsonb_build_object('page_size','100') || case when v_token<>'' then jsonb_build_object('page_token',v_token) else '{}'::jsonb end,
      v_body, v_app_key, v_app_secret, v_access, v_cipher);
    if v_resp->>'error' is not null or (v_resp->>'code')::int <> 0 then
      perform pg_advisory_unlock(421982737);
      return jsonb_build_object('error',coalesce(v_resp->>'error','api_'||(v_resp->>'code')));
    end if;
    v_pages := v_pages + 1;
    for v_order in select value from jsonb_array_elements(coalesce(v_resp->'data'->'orders','[]'::jsonb)) loop
      insert into public.tt_pedidos (order_id, create_time, order_status, currency, payment_total)
      values (v_order->>'id', to_timestamp((v_order->>'create_time')::bigint), v_order->>'status',
              v_order->'payment'->>'currency', nullif(v_order->'payment'->>'total_amount','')::numeric)
      on conflict (order_id) do update set order_status=excluded.order_status, payment_total=excluded.payment_total;
      v_orders := v_orders + 1;
      for v_item in select value from jsonb_array_elements(coalesce(v_order->'line_items','[]'::jsonb)) loop
        insert into public.tt_itens (order_id, line_item_id, seller_sku, sku_id, product_name, line_status, sale_price, original_price, seller_discount, quantity)
        values (v_order->>'id', v_item->>'id', v_item->>'seller_sku', v_item->>'sku_id', v_item->>'product_name',
                v_item->>'display_status', nullif(v_item->>'sale_price','')::numeric,
                nullif(v_item->>'original_price','')::numeric, nullif(v_item->>'seller_discount','')::numeric, 1)
        on conflict (order_id, line_item_id) do update set line_status=excluded.line_status;
        v_items := v_items + 1;
      end loop;
    end loop;
    v_token := coalesce(v_resp->'data'->>'next_page_token','');
    v_more := v_token <> '';
  end loop;
  v_fin := public.tt_fill_finance(400);
  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('tt_cron_semanal', 200,
    coalesce((v_fin->>'fail')::int,0)=0 and (v_fin->>'error') is null,
    case when (v_fin->>'error') is not null then 'FALHA no finance: '||(v_fin->>'error')
         when coalesce((v_fin->>'fail')::int,0)>0 then (v_fin->>'fail')||' pedidos com ERRO real no finance'
         else 'ok' end
    ||' | janela=30d pedidos='||v_orders||' itens='||v_items||' pages='||v_pages
    ||' fin_done='||coalesce(v_fin->>'done','0')
    ||' aguardando_liquidar='||coalesce(v_fin->>'aguardando_liquidar','0')
    ||' throttled_429='||coalesce(v_fin->>'throttled_429','0')
    ||' fin_fail='||coalesce(v_fin->>'fail','0')
    ||' fin_remaining='||coalesce(v_fin->>'remaining','0'));
  perform pg_advisory_unlock(421982737);
  return jsonb_build_object('janela_dias',30,'pedidos',v_orders,'itens',v_items,'pages',v_pages,'finance',v_fin);
end $function$;

-- ====== az_cron_diario (só o passo az-confirmar) ======
CREATE OR REPLACE FUNCTION public.az_cron_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_res2 jsonb; v_t timestamptz;
  v_conf_total int := 0; v_frete_total int := 0; v_guard int := 0; v_loop boolean := true;
BEGIN
  v_t := clock_timestamp();
  v_res := az_edge_call(jsonb_build_object('modo','fechar','dia', v_ontem::text));
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  VALUES ('az-diario', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
    COALESCE((v_res->'body'->>'pedidos')::int,0), COALESCE((v_res->'body'->>'valor')::numeric,0),
    (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  WHILE v_loop AND v_guard < 8 LOOP
    v_res2 := az_edge_call(jsonb_build_object('modo','confirmar','limite',40));
    v_conf_total  := v_conf_total  + COALESCE((v_res2->'body'->>'confirmados')::int,0);
    v_frete_total := v_frete_total + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0);
    v_loop := (COALESCE((v_res2->'body'->>'confirmados')::int,0) + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0)) > 0
              AND COALESCE((v_res2->'body'->>'pendentes')::int,0) > 0;
    v_guard := v_guard + 1;
  END LOOP;
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  VALUES ('az-confirmar', v_ontem, (v_res2->>'http_status')='200', (v_res2->>'http_status')::int, v_conf_total, 0,
    (extract(epoch from clock_timestamp()-v_t)*1000)::int,
    'loops='||v_guard||' com='||v_conf_total||' frete='||v_frete_total, v_res2);

  RETURN jsonb_build_object('ontem', v_ontem,
    'pedidos', COALESCE((v_res->'body'->>'pedidos')::int,0),
    'confirmados', v_conf_total, 'frete_confirmados', v_frete_total, 'loops', v_guard);
END;
$function$;

-- ====== az_cron_semanal ======
CREATE OR REPLACE FUNCTION public.az_cron_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  i int; v_t timestamptz := clock_timestamp(); v_res2 jsonb;
  v_conf_total int := 0; v_frete_total int := 0; v_guard int := 0; v_loop boolean := true;
BEGIN
  for i in 0..30 loop
    perform az_edge_call(jsonb_build_object('modo','fechar','dia',(v_ontem - i)::text));
  end loop;
  WHILE v_loop AND v_guard < 8 LOOP
    v_res2 := az_edge_call(jsonb_build_object('modo','confirmar','limite',40));
    v_conf_total  := v_conf_total  + COALESCE((v_res2->'body'->>'confirmados')::int,0);
    v_frete_total := v_frete_total + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0);
    v_loop := (COALESCE((v_res2->'body'->>'confirmados')::int,0) + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0)) > 0
              AND COALESCE((v_res2->'body'->>'pendentes')::int,0) > 0;
    v_guard := v_guard + 1;
  END LOOP;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('az-semanal', v_ontem, (v_res2->>'http_status')='200', (v_res2->>'http_status')::int, v_conf_total,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          '30d re-fechados + confirmar loops='||v_guard||' com='||v_conf_total||' frete='||v_frete_total, v_res2);
  return jsonb_build_object('ok', true, 'dias', 31, 'confirmados', v_conf_total, 'frete_confirmados', v_frete_total, 'loops', v_guard);
END;
$function$;
