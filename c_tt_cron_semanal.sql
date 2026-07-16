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
end $function$
