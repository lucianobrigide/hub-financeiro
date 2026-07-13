-- ============================================================
-- Reconferência LONGA semanal p/ Shopee, Amazon e TikTok (molde do ml_cron_semanal).
-- Objetivo: pegar mudanças tardias (pedidos que completam/mudam status FORA da janela
-- do diário — Shopee 7d, TikTok 3d, Amazon ontem). Cada uma re-varre 30 dias.
-- Idempotentes (upsert). O agendamento (cron.schedule) vem em migration separada.
-- ============================================================

-- ---------- TikTok: re-busca pedidos 30 dias (upsert atualiza status) + finance ----------
create or replace function public.tt_cron_semanal()
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $function$
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
  values ('tt_cron_semanal', 200, true,
    'janela=30d pedidos='||v_orders||' itens='||v_items||' pages='||v_pages
    ||' fin_done='||coalesce(v_fin->>'done','0')||' fin_remaining='||coalesce(v_fin->>'remaining','0'));
  perform pg_advisory_unlock(421982737);
  return jsonb_build_object('janela_dias',30,'pedidos',v_orders,'itens',v_items,'pages',v_pages,'finance',v_fin);
end $function$;

-- ---------- Amazon: re-fechar 0..30 dias + confirmar (molde ml_cron_semanal) ----------
create or replace function public.az_cron_semanal()
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $function$
declare
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  i int; v_t timestamptz := clock_timestamp(); v_conf jsonb;
begin
  for i in 0..30 loop
    perform az_edge_call(jsonb_build_object('modo','fechar','dia',(v_ontem - i)::text));
  end loop;
  v_conf := az_edge_call(jsonb_build_object('modo','confirmar'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('az-semanal', v_ontem, (v_conf->>'http_status')='200', (v_conf->>'http_status')::int,
          coalesce((v_conf->'body'->>'confirmados')::int,0),
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, '30 dias re-fechados + confirmar', v_conf);
  return jsonb_build_object('ok', true, 'dias', 31, 'confirmados', coalesce((v_conf->'body'->>'confirmados')::int,0));
end $function$;

-- ---------- Shopee: lista COMPLETED 30 dias -> detail novos -> escrow (pega late-complete) ----------
-- get_order_list da Shopee limita a janela a 15 dias -> 2 sub-janelas.
create or replace function public.shopee_cron_semanal()
returns jsonb language plpgsql security definer
set search_path to 'public','extensions'
as $function$
declare
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_win_start timestamptz; v_win_end timestamptz;
  v_resp jsonb; v_more boolean; v_cursor text;
  v_page_sns text[]; v_new_sns text[]; v_all_new text[] := '{}';
  v_batch text[]; v_detail jsonb; v_order jsonb; v_item jsonb; v_sn text; v_income jsonb; v_i int;
  v_listed int := 0; v_inserted int := 0; v_escrow_done int := 0;
begin
  if not pg_try_advisory_lock(421982738) then
    return jsonb_build_object('skipped','already_running');
  end if;
  select decrypted_secret into v_pid  from vault.decrypted_secrets where name='shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name='shopee_partner_key';
  select access_token, shop_id into v_access, v_shop_id from shopee_oauth_state where id=1;
  if v_pid is null or v_pkey is null or v_access is null then
    perform pg_advisory_unlock(421982738); return jsonb_build_object('error','missing_credentials');
  end if;
  if (select expires_at from shopee_oauth_state where id=1) < clock_timestamp() + interval '30 minutes' then
    perform shopee_refresh_token(true);
    select access_token into v_access from shopee_oauth_state where id=1;
  end if;

  v_win_end   := date_trunc('day', clock_timestamp() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '30 days';

  for v_i in 0..1 loop
    v_more := true; v_cursor := '';
    while v_more loop
      v_resp := _sp_api_get('/api/v2/order/get_order_list',
        'time_range_field=create_time'
          || '&time_from=' || extract(epoch from (v_win_start + (v_i*interval '15 days')))::bigint
          || '&time_to='   || extract(epoch from least(v_win_start + ((v_i+1)*interval '15 days'), v_win_end))::bigint
          || '&page_size=100&order_status=COMPLETED'
          || case when v_cursor <> '' then '&cursor=' || v_cursor else '' end,
        v_pid, v_pkey, v_access, v_shop_id);
      if v_resp->>'error' is not null and v_resp->>'error' <> '' then
        perform pg_advisory_unlock(421982738);
        return jsonb_build_object('error', v_resp->>'error', 'listed', v_listed);
      end if;
      if v_resp->'response'->'order_list' is not null then
        select array_agg(el->>'order_sn') into v_page_sns
        from jsonb_array_elements(v_resp->'response'->'order_list') as el;
        if v_page_sns is not null then
          v_listed := v_listed + array_length(v_page_sns,1);
          select array_agg(sn) into v_new_sns from unnest(v_page_sns) as sn
          where not exists (select 1 from shopee_pedidos sp where sp.order_sn = sn);
          if v_new_sns is not null then v_all_new := v_all_new || v_new_sns; end if;
        end if;
      end if;
      v_more := coalesce((v_resp->'response'->>'more')::boolean, false);
      v_cursor := coalesce(v_resp->'response'->>'next_cursor','');
    end loop;
  end loop;

  if array_length(v_all_new,1) is not null and array_length(v_all_new,1) > 0 then
    v_i := 1;
    while v_i <= array_length(v_all_new,1) loop
      v_batch := v_all_new[v_i : least(v_i+49, array_length(v_all_new,1))];
      v_detail := _sp_api_get('/api/v2/order/get_order_detail',
        'order_sn_list=' || array_to_string(v_batch,',') || '&response_optional_fields=item_list',
        v_pid, v_pkey, v_access, v_shop_id);
      if v_detail->'response'->'order_list' is not null then
        for v_order in select value from jsonb_array_elements(v_detail->'response'->'order_list') loop
          insert into shopee_pedidos (order_sn, create_time, pay_time, order_status)
          values (v_order->>'order_sn', to_timestamp((v_order->>'create_time')::bigint),
            case when (v_order->>'pay_time')::bigint > 0 then to_timestamp((v_order->>'pay_time')::bigint) end,
            v_order->>'order_status')
          on conflict (order_sn) do nothing;
          for v_item in select value from jsonb_array_elements(coalesce(v_order->'item_list','[]'::jsonb)) loop
            insert into shopee_itens (order_sn, item_id, model_id, item_sku, model_sku, item_name, quantity, unit_price, original_price)
            values (v_order->>'order_sn', (v_item->>'item_id')::bigint, coalesce((v_item->>'model_id')::bigint,0),
              v_item->>'item_sku', v_item->>'model_sku', v_item->>'item_name',
              coalesce((v_item->>'model_quantity_purchased')::int,1),
              (v_item->>'model_discounted_price')::numeric, (v_item->>'model_original_price')::numeric)
            on conflict (order_sn, item_id, model_id) do nothing;
          end loop;
          v_inserted := v_inserted + 1;
        end loop;
      end if;
      v_i := v_i + 50;
    end loop;
  end if;

  for v_sn in select order_sn from shopee_pedidos where selling_price is null order by create_time limit 300 loop
    v_resp := _sp_api_get('/api/v2/payment/get_escrow_detail','order_sn='||v_sn,v_pid,v_pkey,v_access,v_shop_id);
    v_income := v_resp->'response'->'order_income';
    if v_income is not null then
      update shopee_pedidos set
        selling_price=(v_income->>'cost_of_goods_sold')::numeric, net_commission=(v_income->>'net_commission_fee')::numeric,
        net_service_fee=(v_income->>'net_service_fee')::numeric, shipping_fee=(v_income->>'actual_shipping_fee')::numeric,
        escrow_amount=(v_income->>'escrow_amount')::numeric, escrow_adjusted=(v_income->>'escrow_amount_after_adjustment')::numeric,
        buyer_total=(v_income->>'buyer_total_amount')::numeric, ams_commission=coalesce((v_income->>'order_ams_commission_fee')::numeric,0)
      where order_sn = v_sn;
      v_escrow_done := v_escrow_done + 1;
    end if;
  end loop;

  insert into oauth_refresh_log(conta, http_status, success, message)
  values ('shopee_cron_semanal', 200, true,
    'janela=30d listed='||v_listed||' new='||v_inserted||' escrow='||v_escrow_done);
  perform pg_advisory_unlock(421982738);
  return jsonb_build_object('janela_dias',30,'listed',v_listed,'new_orders',v_inserted,'escrow_done',v_escrow_done);
end $function$;

revoke all on function public.tt_cron_semanal()     from public, anon, authenticated;
revoke all on function public.az_cron_semanal()     from public, anon, authenticated;
revoke all on function public.shopee_cron_semanal() from public, anon, authenticated;
grant execute on function public.tt_cron_semanal()     to service_role;
grant execute on function public.az_cron_semanal()     to service_role;
grant execute on function public.shopee_cron_semanal() to service_role;
