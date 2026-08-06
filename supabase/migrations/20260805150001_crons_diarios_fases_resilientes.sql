-- Crons diários ML/TikTok/Amazon: fases resilientes (mesmo padrão da Shopee,
-- migration 20260805140001, motivada pelo incidente de 05/08/2026).
--
-- PROBLEMA COMUM: cada cron roda numa transação única do pg_cron. Uma exceção
-- crua (ex.: timeout SSL do extensions.http) aborta a função inteira e o
-- ROLLBACK descarta o trabalho E os logs dos passos que já tinham dado certo —
-- o dia some sem rastro no log de aplicação.
--
-- O FIX em cada função: cada passo roda num bloco BEGIN/EXCEPTION próprio
-- (subtransação). Exceção num passo perde só aquele passo, registra a falha no
-- log de aplicação (ml_cron_log / oauth_refresh_log) e segue para o próximo.
-- A lógica de negócio dos passos não muda.
--
--   - ml_cron_diario: 10 passos (fechar, frete, ads, full, afiliados, difal,
--     seguidores, billing, billing_ant, reconferir7), cada um com seu log.
--   - tt_cron_diario: 2 fases (pedidos, finance) + log SEMPRE em oauth_refresh_log
--     (erro de API na listagem, que antes dava RETURN precoce sem log, agora é
--     exceção capturada e logada).
--   - az_cron_diario: 2 passos (fechar, confirmar), cada um com seu log.

-- ─────────────────────────────── ML ───────────────────────────────

CREATE OR REPLACE FUNCTION public.ml_cron_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_frete_ok boolean; v_frete_err text; v_rec_falhas int := 0;
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_t timestamptz; d date; i int;
  v_frete_grav int := 0; v_restam boolean := true; v_guard int := 0;
begin
  if not pg_try_advisory_lock(421982739) then
    return jsonb_build_object('skipped', 'already_running');
  end if;

  -- FECHAR (vendas de ontem)
  begin
    v_t := clock_timestamp();
    v_res := ml_edge_call(jsonb_build_object('modo','fechar','dia',v_ontem::text));
    insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,valor,duracao_ms,mensagem,resposta)
    values ('diario_fechar', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
            (v_res->'body'->'fechar'->>'upsertados')::int, (v_res->'body'->'fechar'->>'valorDia')::numeric,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            case when (v_res->>'http_status')='200' then 'ok'
                 else coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                               'HTTP '||coalesce(v_res->>'http_status','?')) end, v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_fechar', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- FRETE (chunks)
  begin
    v_t := clock_timestamp();
    v_frete_ok := true; v_frete_err := null;
    while v_restam and v_guard < 25 loop
      v_res := ml_edge_call(jsonb_build_object('modo','frete','janela',30,'limite',250));
      if (v_res->>'http_status') <> '200' then
        v_frete_ok := false;
        v_frete_err := coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                                'HTTP '||coalesce(v_res->>'http_status','?'));
        exit;  -- não finge que acabou: sai e loga a falha
      end if;
      v_frete_grav := v_frete_grav + coalesce((v_res->'body'->'frete'->>'gravados')::int, 0);
      v_restam := coalesce((v_res->'body'->'frete'->>'restam')::boolean, false);
      v_guard := v_guard + 1;
    end loop;
    -- estourar o guard com pendentes restando também é falha (não drenou tudo)
    if v_restam and v_guard >= 25 then
      v_frete_ok := false;
      v_frete_err := 'guard 25 chunks estourado com pendentes restando';
    end if;
    insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_frete', v_ontem, v_frete_ok, v_frete_grav,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            coalesce(v_frete_err, 'chunks='||v_guard||' gravados='||v_frete_grav), v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem)
    values ('diario_frete', v_ontem, false, v_frete_grav,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- ADS
  begin
    v_t := clock_timestamp();
    v_res := ml_edge_call(jsonb_build_object('modo','ads','dia',v_ontem::text));
    insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,duracao_ms,mensagem,resposta)
    values ('diario_ads', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            case when (v_res->>'http_status')='200' then 'ok'
                 else coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                               'HTTP '||coalesce(v_res->>'http_status','?')) end, v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_ads', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- FULL
  begin
    v_t := clock_timestamp();
    v_res := ml_edge_call(jsonb_build_object('modo','full'));
    insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_full', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
            (v_res->'body'->'full'->>'gravados')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            case when (v_res->>'http_status')='200' then 'ok'
                 else coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                               'HTTP '||coalesce(v_res->>'http_status','?')) end, v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_full', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- AFILIADOS (CVAF)
  begin
    v_t := clock_timestamp();
    v_res := ml_edge_passo('afiliados','CVAF','ml_afiliados');
    insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_afiliados', v_ontem, (v_res->>'completo')::boolean, (v_res->>'http_status')::int,
            (v_res->>'no_banco')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            coalesce(v_res->>'erro', v_res->>'aviso', 'ok'), v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_afiliados', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- DIFAL (CDIFAL) -- pesca ciclo atual + anterior, regua creation_date.
  begin
    v_t := clock_timestamp();
    v_res := ml_edge_passo('difal','CDIFAL','ml_difal');
    insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_difal', v_ontem, (v_res->>'completo')::boolean, (v_res->>'http_status')::int,
            (v_res->>'no_banco')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            coalesce(v_res->>'erro', v_res->>'aviso', 'ok'), v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_difal', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- SEGUIDORES (CDLIT) -- campanha Publicidade "Aumentar seguidores".
  -- billing, regua creation_date, ciclo atual + anterior. Grava em ml_ads_diario
  -- (produto='seguidores') -> entra na linha ADS via ml_ads().
  begin
    v_t := clock_timestamp();
    v_res := ml_edge_passo('seguidores');
    insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_seguidores', v_ontem, (v_res->>'completo')::boolean, (v_res->>'http_status')::int,
            (v_res->'resposta'->'body'->'seguidores'->>'dias')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            coalesce(v_res->>'erro', v_res->>'aviso', 'ok'), v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_seguidores', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- BILLING (bonificações + fricção): BPAD abate o ADS; CXDED/CDSDB/CFPB/CXDID
  -- (menos os estornos espelho) viram a linha "Custo Devoluções". Régua creation_date
  -- mês-calendário -> pesca a fatura do mês atual e a anterior (ciclo fecha ~dia 22).
  -- ml_fill_billing confere contra o `total` da API e re-tenta (a API trunca em silêncio).
  begin
    v_t := clock_timestamp();
    v_res := ml_fill_billing(to_char((now() at time zone 'America/Sao_Paulo')::date, 'YYYY-MM-01'));
    insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_billing', v_ontem,
            ((v_res->>'ok')::boolean is true and coalesce((v_res->>'completo')::boolean, true)), (v_res->>'no_banco')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            case when (v_res->>'ok')::boolean is not true then coalesce(v_res->>'erro','falhou')
                 when (v_res->>'verificado')::boolean is not true then coalesce(v_res->>'aviso','nao verificado')
                 when (v_res->>'completo')::boolean then 'ok'
                 else coalesce(v_res->>'erro','INCOMPLETO') end, v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_billing', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  begin
    v_t := clock_timestamp();
    v_res := ml_fill_billing(to_char(((now() at time zone 'America/Sao_Paulo')::date - interval '1 month')::date, 'YYYY-MM-01'));
    insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
    values ('diario_billing_ant', v_ontem,
            ((v_res->>'ok')::boolean is true and coalesce((v_res->>'completo')::boolean, true)), (v_res->>'no_banco')::int,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            case when (v_res->>'ok')::boolean is not true then coalesce(v_res->>'erro','falhou')
                 when (v_res->>'verificado')::boolean is not true then coalesce(v_res->>'aviso','nao verificado')
                 when (v_res->>'completo')::boolean then 'ok'
                 else coalesce(v_res->>'erro','INCOMPLETO') end, v_res);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_billing_ant', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  -- RECONFERIR 7 DIAS
  begin
    v_t := clock_timestamp();
    v_rec_falhas := 0;
    for i in 0..6 loop
      d := v_ontem - i;
      v_res := ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',d::text));
      if (v_res->>'http_status') <> '200' then v_rec_falhas := v_rec_falhas + 1; end if;
    end loop;
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_reconferir7', v_ontem, (v_rec_falhas = 0),
            (extract(epoch from clock_timestamp()-v_t)*1000)::int,
            case when v_rec_falhas = 0 then '7 dias'
                 else v_rec_falhas||' de 7 dias FALHARAM' end);
  exception when others then
    insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
    values ('diario_reconferir7', v_ontem, false,
            (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  end;

  perform pg_advisory_unlock(421982739);
  return jsonb_build_object('ontem', v_ontem, 'frete_gravados', v_frete_grav, 'frete_chunks', v_guard);
end $function$;

-- ─────────────────────────────── TikTok ───────────────────────────────

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
  -- erro capturado por fase (NULL = fase ok)
  v_err_pedidos text; v_err_fin text; v_erros text; v_ok boolean;
BEGIN
  IF NOT pg_try_advisory_lock(421982737) THEN
    RETURN jsonb_build_object('skipped','already_running');
  END IF;
  SELECT decrypted_secret INTO v_app_key    FROM vault.decrypted_secrets WHERE name='tt_app_key';
  SELECT decrypted_secret INTO v_app_secret FROM vault.decrypted_secrets WHERE name='tt_app_secret';
  SELECT access_token, shop_cipher INTO v_access, v_cipher FROM public.tt_oauth_state WHERE id=1;
  IF v_app_key IS NULL OR v_access IS NULL THEN
    INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
    VALUES ('tt_cron', NULL, false, 'missing_credentials');
    PERFORM pg_advisory_unlock(421982737);
    RETURN jsonb_build_object('error','missing_credentials');
  END IF;
  -- Refresh preventivo do token: se falhar, segue com o token atual — as fases
  -- registram individualmente o que não conseguirem fazer.
  BEGIN
    IF (SELECT expires_at FROM public.tt_oauth_state WHERE id=1) < clock_timestamp() + interval '30 minutes' THEN
      PERFORM public.tt_refresh_token(true);
      SELECT access_token INTO v_access FROM public.tt_oauth_state WHERE id=1;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  v_win_end   := date_trunc('day', clock_timestamp() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_win_start := v_win_end - interval '7 days';  -- 3->7: alinha com ML/Shopee (janela curta cria vao)
  v_ge := extract(epoch from v_win_start)::bigint;
  v_lt := extract(epoch from v_win_end)::bigint;
  v_body := json_build_object('create_time_ge',v_ge,'create_time_lt',v_lt)::text;

  -- FASE 1: pedidos da janela (erro de API vira exceção capturada e logada,
  -- não RETURN precoce sem log)
  BEGIN
    WHILE v_more LOOP
      v_resp := public._tt_post('/order/202309/orders/search',
        jsonb_build_object('page_size','100') || CASE WHEN v_token<>'' THEN jsonb_build_object('page_token',v_token) ELSE '{}'::jsonb END,
        v_body, v_app_key, v_app_secret, v_access, v_cipher);
      IF v_resp->>'error' IS NOT NULL OR (v_resp->>'code')::int <> 0 THEN
        RAISE EXCEPTION 'orders/search: % %',
          coalesce(v_resp->>'error','api_'||(v_resp->>'code')), coalesce(v_resp->>'message','');
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
  EXCEPTION WHEN OTHERS THEN
    v_err_pedidos := SQLERRM;
  END;

  -- FASE 2: finance dos pedidos pendentes (fila re-tentada todo dia)
  BEGIN
    v_fin := public.tt_fill_finance(200);
  EXCEPTION WHEN OTHERS THEN
    v_err_fin := SQLERRM;
  END;

  -- Log SEMPRE (sucesso ou falha) — concat_ws descarta os NULL das fases ok.
  v_erros := concat_ws(' | ', 'pedidos: ' || v_err_pedidos, 'finance: ' || v_err_fin);
  v_ok := (v_erros IS NULL OR v_erros = '')
          AND coalesce((v_fin->>'fail')::int, 0) = 0 AND (v_fin->>'error') IS NULL;
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('tt_cron', CASE WHEN v_ok THEN 200 END, v_ok,
    case when v_erros is not null and v_erros <> '' then 'ERROS: '||v_erros
         when (v_fin->>'error') is not null then 'FALHA no finance: '||(v_fin->>'error')
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
    'pedidos_na_janela',v_orders,'itens',v_items,'pages',v_pages,'finance',v_fin,
    'erros', CASE WHEN v_erros IS NULL OR v_erros = '' THEN NULL ELSE v_erros END);
END $function$;

-- ─────────────────────────────── Amazon ───────────────────────────────

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
  -- FECHAR (vendas de ontem)
  BEGIN
    v_t := clock_timestamp();
    v_res := az_edge_call(jsonb_build_object('modo','fechar','dia', v_ontem::text));
    INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
    VALUES ('az-diario', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
      COALESCE((v_res->'body'->>'pedidos')::int,0), COALESCE((v_res->'body'->>'valor')::numeric,0),
      (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, duracao_ms, mensagem)
    VALUES ('az-diario', v_ontem, false,
      (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  END;

  -- CONFIRMAR (comissão/frete reais via Finances API)
  BEGIN
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
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, pedidos, duracao_ms, mensagem)
    VALUES ('az-confirmar', v_ontem, false, v_conf_total,
      (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'EXCEPTION: '||SQLERRM);
  END;

  RETURN jsonb_build_object('ontem', v_ontem,
    'pedidos', COALESCE((v_res->'body'->>'pedidos')::int,0),
    'confirmados', v_conf_total, 'frete_confirmados', v_frete_total, 'loops', v_guard);
END;
$function$;
