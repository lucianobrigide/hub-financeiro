-- Função que o pg_cron dispara: fecha ONTEM (America/Sao_Paulo) via Edge ml-ingest-dia
-- e grava a resposta na ml_cron_log. Reusa o padrão síncrono do ml_refresh_token
-- (extensions.http). x-api-key vem do Vault (ml_token_key); URL de functions é pública
-- (não-segredo), constante como a URL do ML no ml_refresh_token.
-- A guarda do dia corrente vive na Edge; aqui NUNCA mandamos hoje (sempre ontem).
create or replace function public.ml_cron_fechar_ontem()
returns jsonb
language plpgsql security definer
set search_path to 'public','extensions','vault'
as $function$
declare
  v_url    text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/ml-ingest-dia';
  v_key    text;
  v_dia    date := (now() at time zone 'America/Sao_Paulo')::date - 1;  -- ontem SP
  v_status int;  v_raw text;  v_body jsonb;
  v_t0     timestamptz := clock_timestamp();
  v_ped    int;  v_valor numeric;  v_ok boolean;  v_msg text;  v_dur int;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'ml_token_key';
  if v_key is null or v_key = '' then
    insert into public.ml_cron_log(job, dia_alvo, sucesso, mensagem)
    values ('fechar_ontem', v_dia, false, 'ml_token_key ausente no Vault');
    return jsonb_build_object('ok', false, 'error', 'missing_key');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '140000');  -- < 150s da Edge

  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    v_url,
    array[ extensions.http_header('x-api-key', v_key) ],
    'application/json',
    json_build_object('modo', 'fechar', 'dia', v_dia::text)::text
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;
  v_dur  := (extract(epoch from clock_timestamp() - v_t0) * 1000)::int;

  if v_status = 200 and v_body ? 'fechar' then
    if coalesce((v_body->'fechar'->>'recusado')::boolean, false) then
      v_ok := false; v_ped := null; v_valor := null;
      v_msg := 'recusado: ' || coalesce(v_body->'fechar'->>'motivo', 'dia corrente');
    else
      v_ok := true;
      v_ped   := (v_body->'fechar'->>'upsertados')::int;
      v_valor := (v_body->'fechar'->>'valorDia')::numeric;
      v_msg   := 'ok';
    end if;
  else
    v_ok := false; v_ped := null; v_valor := null;
    v_msg := 'http ' || coalesce(v_status::text, '?') || ': ' || left(coalesce(v_raw, 'sem corpo'), 300);
  end if;

  insert into public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  values ('fechar_ontem', v_dia, v_ok, v_status, v_ped, v_valor, v_dur, v_msg, v_body);

  return jsonb_build_object('ok', v_ok, 'dia', v_dia, 'pedidos', v_ped, 'valor', v_valor, 'http_status', v_status);
end;
$function$;

revoke all on function public.ml_cron_fechar_ontem() from public, anon, authenticated;
grant execute on function public.ml_cron_fechar_ontem() to service_role;
