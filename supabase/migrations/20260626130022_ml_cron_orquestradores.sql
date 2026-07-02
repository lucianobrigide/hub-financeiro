-- Orquestradores do fluxo noturno/semanal. Reusam o padrão síncrono (extensions.http)
-- do ml_cron_fechar_ontem, chamando a Edge ml-ingest-dia passo a passo e logando em
-- ml_cron_log. NÃO são agendados aqui (cron.schedule vem no checkpoint).

-- helper: chama a Edge (x-api-key do Vault) e devolve {http_status, body}
create or replace function public.ml_edge_call(p_body jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','extensions','vault'
as $function$
declare
  v_url text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/ml-ingest-dia';
  v_key text; v_status int; v_raw text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'ml_token_key';
  if v_key is null or v_key = '' then return jsonb_build_object('http_status', 0, 'body', jsonb_build_object('error','missing_key')); end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '150000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST', v_url, array[ extensions.http_header('x-api-key', v_key) ],
    'application/json', p_body::text
  )::extensions.http_request) as r;
  return jsonb_build_object('http_status', v_status,
    'body', case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else to_jsonb(coalesce(v_raw,'')) end);
end $function$;

-- fluxo DIÁRIO: fechar(ontem) → frete(loop) → ADS(ontem) → Full → reconferir 7d
create or replace function public.ml_cron_diario()
returns jsonb language plpgsql security definer set search_path to 'public','extensions','vault'
as $function$
declare
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_t timestamptz; d date; i int;
  v_frete_grav int := 0; v_restam boolean := true; v_guard int := 0;
begin
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','fechar','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,valor,duracao_ms,mensagem,resposta)
  values ('diario_fechar', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'fechar'->>'upsertados')::int, (v_res->'body'->'fechar'->>'valorDia')::numeric,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  while v_restam and v_guard < 25 loop
    v_res := ml_edge_call(jsonb_build_object('modo','frete','janela',30,'limite',250));
    v_frete_grav := v_frete_grav + coalesce((v_res->'body'->'frete'->>'gravados')::int, 0);
    v_restam := coalesce((v_res->'body'->'frete'->>'restam')::boolean, false);
    v_guard := v_guard + 1;
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem)
  values ('diario_frete', v_ontem, true, v_frete_grav,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'chunks='||v_guard||' gravados='||v_frete_grav);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','ads','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,duracao_ms,mensagem,resposta)
  values ('diario_ads', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','full'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_full', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'full'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  for i in 0..6 loop
    d := v_ontem - i;
    perform ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',d::text));
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('diario_reconferir7', v_ontem, true, (extract(epoch from clock_timestamp()-v_t)*1000)::int, '7 dias');

  return jsonb_build_object('ontem', v_ontem, 'frete_gravados', v_frete_grav, 'frete_chunks', v_guard);
end $function$;

-- fluxo SEMANAL: reconferir 30 dias (1 disparo/dia)
create or replace function public.ml_cron_semanal()
returns jsonb language plpgsql security definer set search_path to 'public','extensions','vault'
as $function$
declare v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1; i int; v_t timestamptz := clock_timestamp();
begin
  for i in 0..30 loop
    perform ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',(v_ontem - i)::text));
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('semanal_reconferir30', v_ontem, true, (extract(epoch from clock_timestamp()-v_t)*1000)::int, '30 dias');
  return jsonb_build_object('ok', true, 'dias', 31);
end $function$;

revoke all on function public.ml_edge_call(jsonb) from public, anon, authenticated;
revoke all on function public.ml_cron_diario() from public, anon, authenticated;
revoke all on function public.ml_cron_semanal() from public, anon, authenticated;
grant execute on function public.ml_edge_call(jsonb) to service_role;
grant execute on function public.ml_cron_diario() to service_role;
grant execute on function public.ml_cron_semanal() to service_role;
