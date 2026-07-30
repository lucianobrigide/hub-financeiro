-- Custódia de token Amazon Ads API (LwA, escopo advertising::campaign_management).
-- Prefixo azads_ — o az_ já é da SP-API (outra app LwA, outro refresh_token).
-- Padrão idêntico ao ML/az: refresh_token e credenciais SÓ no Vault
-- (azads_client_id/_secret, azads_refresh_token, azads_token_key); access_token
-- ~1h cacheado em azads_oauth_state (singleton id=1). A troca do authorization
-- code acontece DENTRO do Postgres (azads_exchange_code) — o client_secret nunca
-- sai do banco; a rota de callback na Vercel só repassa o code.
-- Nenhum segredo neste arquivo (placeholders __SET_ME__).

-- Estado não-sensível (singleton id=1). profile_id/currency preenchidos na
-- FASE 2 (descoberta via GET /v2/profiles), ficam null até lá.
create table if not exists public.azads_oauth_state (
  id            int primary key check (id = 1),
  access_token  text,
  token_type    text,
  scope         text,
  expires_at    timestamptz,
  refreshed_at  timestamptz,
  profile_id    text,
  country_code  text,
  currency_code text,
  updated_at    timestamptz not null default now()
);
comment on table public.azads_oauth_state is
  'Estado nao-sensivel do token Amazon Ads (LwA). refresh_token NAO fica aqui — vive em vault.secrets (azads_refresh_token). Linha unica id=1.';
alter table public.azads_oauth_state enable row level security;
insert into public.azads_oauth_state (id) values (1) on conflict (id) do nothing;

-- Placeholders no Vault (valores reais semeados fora de migration — segredo
-- não é versionável). Guard: só cria se ainda não existir.
do $$
declare s text;
begin
  foreach s in array array['azads_client_id','azads_client_secret','azads_refresh_token','azads_token_key']
  loop
    if not exists (select 1 from vault.secrets where name = s) then
      perform vault.create_secret('__SET_ME__', s, 'Amazon Ads API (LwA) — semeado fora de migration');
    end if;
  end loop;
end $$;

-- Valida x-api-key da Edge Function amazon-ads-token contra o Vault (fail-closed)
create or replace function public.azads_token_check(p_key text)
returns boolean language plpgsql security definer
set search_path to 'public','vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected from vault.decrypted_secrets where name = 'azads_token_key';
  if v_expected is null or v_expected = '' or v_expected = '__SET_ME__' then return false; end if;
  return p_key = v_expected;
end $$;

-- Leitura do estado (sem segredos)
create or replace function public.azads_get_state()
returns table(access_token text, expires_at timestamptz, profile_id text)
language sql security definer set search_path to 'public'
as $$ select access_token, expires_at, profile_id from public.azads_oauth_state where id = 1; $$;

-- Troca do authorization code (uso único, expira em minutos) por tokens.
-- Chamada UMA vez pela rota /api/auth/callback-amazon-ads. Falha alto: devolve
-- ok=false com status e corpo do erro, e loga em oauth_refresh_log.
create or replace function public.azads_exchange_code(p_code text)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_redirect constant text := 'https://hub-financeiro-omega.vercel.app/api/auth/callback-amazon-ads';
  v_cid text; v_csec text; v_rt_id uuid;
  v_status int; v_raw text; v_body jsonb;
  v_access text; v_rt text; v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982733);  -- mesma chave do azads_refresh_token

  if p_code is null or p_code = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_code');
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
      || '&redirect_uri='  || extensions.urlencode(v_redirect)
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

-- Refresh atômico sob advisory lock — clone do az_refresh_token (LwA não
-- rotaciona o refresh_token; se um novo vier no corpo, persiste por segurança).
create or replace function public.azads_refresh_token(p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_margin  interval := case when p_force then interval '2 minutes' else interval '10 minutes' end;
  v_exp     timestamptz;
  v_cid text; v_csec text; v_rt text; v_rt_id uuid;
  v_status int; v_raw text; v_body jsonb;
  v_access text; v_new_rt text; v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982733);

  select expires_at into v_exp from public.azads_oauth_state where id = 1;
  if not p_force and v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true, 'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'azads_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'azads_client_secret';
  select decrypted_secret into v_rt   from vault.decrypted_secrets where name = 'azads_refresh_token';
  select id              into v_rt_id from vault.secrets          where name = 'azads_refresh_token';
  if v_cid is null or v_cid = '__SET_ME__' or v_csec is null or v_csec = '__SET_ME__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('azads_brigide', null, false, 'credenciais azads_* ausentes no Vault');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
  end if;
  if v_rt is null or v_rt = '' or v_rt = '__SET_ME__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('azads_brigide', null, false, 'azads_refresh_token nao semeado no Vault (autorizar o app via /api/auth/callback-amazon-ads)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST', 'https://api.amazon.com/auth/o2/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/x-www-form-urlencoded',
    'grant_type=refresh_token'
      || '&refresh_token=' || extensions.urlencode(v_rt)
      || '&client_id='     || extensions.urlencode(v_cid)
      || '&client_secret=' || extensions.urlencode(v_csec)
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_access  := v_body->>'access_token';
    v_expin   := coalesce((v_body->>'expires_in')::bigint, 3600);
    v_new_exp := now() + (v_expin || ' seconds')::interval;
    v_new_rt  := v_body->>'refresh_token';
    if v_new_rt is not null and v_new_rt <> '' and v_new_rt <> v_rt then
      perform vault.update_secret(v_rt_id, v_new_rt);
    end if;
    update public.azads_oauth_state
       set access_token = v_access, token_type = v_body->>'token_type',
           expires_at = v_new_exp, refreshed_at = now(), updated_at = now()
     where id = 1;
    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('azads_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);
    return jsonb_build_object('refreshed', true, 'valid', true, 'expires_at', v_new_exp);
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('azads_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_failed', 'http_status', v_status);
end $$;

revoke all on function public.azads_token_check(text) from public, anon, authenticated;
revoke all on function public.azads_get_state() from public, anon, authenticated;
revoke all on function public.azads_exchange_code(text) from public, anon, authenticated;
revoke all on function public.azads_refresh_token(boolean) from public, anon, authenticated;
grant execute on function public.azads_token_check(text) to service_role;
grant execute on function public.azads_get_state() to service_role;
grant execute on function public.azads_exchange_code(text) to service_role;
grant execute on function public.azads_refresh_token(boolean) to service_role;
