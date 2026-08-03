-- Plano B do callback Amazon Ads: a Vercel está pausada por estouro de cota
-- (3M/1M edge requests, só religa pagando) e o callback lá está morto. O callback
-- passa a viver em Edge Function do Supabase (amazon-ads-callback, padrão
-- tt-oauth-callback), que independe da Vercel. O redirect_uri enviado na troca
-- do code TEM que ser idêntico ao usado no authorize, então azads_exchange_code
-- ganha o parâmetro p_redirect_uri — restrito à allowlist das duas URLs
-- conhecidas (Supabase e Vercel; a rota da Vercel continua no repo e volta a
-- funcionar se a conta for reativada um dia).
-- DROP obrigatório: assinatura nova com default criaria overload ambíguo.

drop function if exists public.azads_exchange_code(text);

create function public.azads_exchange_code(
  p_code text,
  p_redirect_uri text default 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/amazon-ads-callback'
)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_cid text; v_csec text; v_rt_id uuid;
  v_status int; v_raw text; v_body jsonb;
  v_access text; v_rt text; v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982733);  -- mesma chave do azads_refresh_token

  if p_code is null or p_code = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_code');
  end if;

  if p_redirect_uri not in (
    'https://klwczmapuupensozxbsr.supabase.co/functions/v1/amazon-ads-callback',
    'https://hub-financeiro-omega.vercel.app/api/auth/callback-amazon-ads'
  ) then
    return jsonb_build_object('ok', false, 'error', 'redirect_uri_fora_da_allowlist');
  end if;

  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'azads_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'azads_client_secret';
  select id              into v_rt_id from vault.secrets          where name = 'azads_refresh_token';
  if v_cid is null or v_cid = '__SET_ME__' or v_csec is null or v_csec = '__SET_ME__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('azads_brigide', null, false, 'exchange_code: credenciais azads_* ausentes no Vault');
    return jsonb_build_object('ok', false, 'error', 'missing_credentials');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST', 'https://api.amazon.com/auth/o2/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/x-www-form-urlencoded',
    'grant_type=authorization_code'
      || '&code='          || extensions.urlencode(p_code)
      || '&redirect_uri='  || extensions.urlencode(p_redirect_uri)
      || '&client_id='     || extensions.urlencode(v_cid)
      || '&client_secret=' || extensions.urlencode(v_csec)
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' and v_body ? 'refresh_token' then
    v_access  := v_body->>'access_token';
    v_rt      := v_body->>'refresh_token';
    v_expin   := coalesce((v_body->>'expires_in')::bigint, 3600);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    -- 1) PRIMEIRO o refresh_token no Vault (mesma transação = atômico)
    perform vault.update_secret(v_rt_id, v_rt);

    -- 2) estado não-sensível
    update public.azads_oauth_state
       set access_token = v_access, token_type = v_body->>'token_type',
           scope = v_body->>'scope', expires_at = v_new_exp,
           refreshed_at = now(), updated_at = now()
     where id = 1;

    -- 3) log (sem valores sensíveis)
    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('azads_brigide', v_status, true, 'ok (authorization_code trocado, Vault semeado)',
            extract(epoch from v_new_exp)::bigint);
    return jsonb_build_object('ok', true, 'expires_at', v_new_exp);
  end if;

  -- Falha alto: code expirado/reusado vem como 400 invalid_grant. Corpo de erro
  -- LwA não contém segredos (error + error_description).
  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('azads_brigide', v_status, false,
          'exchange_code FALHOU: ' || left(coalesce(v_raw, 'sem corpo'), 400));
  return jsonb_build_object('ok', false, 'error', 'exchange_failed',
                            'http_status', v_status,
                            'detail', left(coalesce(v_raw, 'sem corpo'), 400));
end $$;

revoke all on function public.azads_exchange_code(text, text) from public, anon, authenticated;
grant execute on function public.azads_exchange_code(text, text) to service_role;
