-- Custódia de token TINY (Olist) — Keycloak OIDC, clone do padrão ML/Amazon.
-- Access token ~4h, refresh token 24h e ROTACIONA (regravar no Vault a cada uso).
-- Segredos no Vault: tiny_client_id, tiny_client_secret, tiny_refresh_token, tiny_token_key.
-- Nenhum segredo neste arquivo.

-- Estado não-sensível (singleton id=1)
create table if not exists public.tiny_oauth_state (
  id            int primary key check (id = 1),
  access_token  text,
  token_type    text,
  scope         text,
  expires_at    timestamptz,
  refreshed_at  timestamptz,
  updated_at    timestamptz not null default now()
);
alter table public.tiny_oauth_state enable row level security;
insert into public.tiny_oauth_state (id) values (1) on conflict (id) do nothing;

-- Valida x-api-key contra Vault (fail-closed)
create or replace function public.tiny_token_check(p_key text)
returns boolean language plpgsql security definer
set search_path to 'public', 'vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected
    from vault.decrypted_secrets where name = 'tiny_token_key';
  if v_expected is null or v_expected = '' then return false; end if;
  return p_key = v_expected;
end $$;

-- Leitura do estado (sem segredos)
create or replace function public.tiny_get_state()
returns table(access_token text, expires_at timestamptz)
language sql security definer set search_path to 'public'
as $$ select access_token, expires_at from public.tiny_oauth_state where id = 1; $$;

-- Troca authorization code por tokens (chamado pelo callback Edge).
-- Client secret NUNCA sai do PG — a chamada HTTP ao Keycloak acontece aqui dentro.
create or replace function public.tiny_exchange_code(p_code text, p_redirect_uri text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_cid text; v_csec text; v_rt_id uuid;
  v_status int; v_raw text; v_body jsonb;
  v_expin bigint; v_new_exp timestamptz;
begin
  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'tiny_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'tiny_client_secret';
  select id              into v_rt_id from vault.secrets          where name = 'tiny_refresh_token';

  if v_cid is null or v_csec is null then
    return jsonb_build_object('ok', false, 'error', 'missing_credentials');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    'https://accounts.tiny.com.br/realms/tiny/protocol/openid-connect/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/x-www-form-urlencoded',
    'grant_type=authorization_code'
      || '&code='          || extensions.urlencode(p_code)
      || '&redirect_uri='  || extensions.urlencode(p_redirect_uri)
      || '&client_id='     || extensions.urlencode(v_cid)
      || '&client_secret=' || extensions.urlencode(v_csec)
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_expin  := coalesce((v_body->>'expires_in')::bigint, 14400);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    if v_body ? 'refresh_token' and (v_body->>'refresh_token') <> '' then
      perform vault.update_secret(v_rt_id, v_body->>'refresh_token');
    end if;

    update public.tiny_oauth_state
       set access_token = v_body->>'access_token',
           token_type   = v_body->>'token_type',
           scope        = v_body->>'scope',
           expires_at   = v_new_exp,
           refreshed_at = now(),
           updated_at   = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('tiny_brigide', v_status, true, 'initial_auth_ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('ok', true, 'expires_in', v_expin, 'scope', v_body->>'scope');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('tiny_brigide', v_status, false, 'exchange_failed: ' || left(coalesce(v_raw, 'sem corpo'), 500));

  return jsonb_build_object('ok', false, 'error', 'token_exchange_failed', 'http_status', v_status,
                            'detail', v_body->>'error_description');
end $$;

-- Refresh atômico sob advisory lock (Keycloak rotaciona: regrava refresh_token novo)
create or replace function public.tiny_refresh_token(p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_margin  interval := case when p_force then interval '2 minutes' else interval '10 minutes' end;
  v_exp     timestamptz;
  v_cid text; v_csec text; v_rt text; v_rt_id uuid;
  v_status int; v_raw text; v_body jsonb;
  v_access text; v_new_rt text; v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982733);

  select expires_at into v_exp from public.tiny_oauth_state where id = 1;

  if not p_force and v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true, 'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'tiny_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'tiny_client_secret';
  select decrypted_secret into v_rt   from vault.decrypted_secrets where name = 'tiny_refresh_token';
  select id              into v_rt_id from vault.secrets          where name = 'tiny_refresh_token';

  if v_cid is null or v_csec is null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('tiny_brigide', null, false, 'tiny_client_id/tiny_client_secret ausentes no Vault');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
  end if;

  if v_rt is null or v_rt = '' or v_rt = '__SET_ME__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('tiny_brigide', null, false, 'tiny_refresh_token nao semeado (autorize o app primeiro)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    'https://accounts.tiny.com.br/realms/tiny/protocol/openid-connect/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/x-www-form-urlencoded',
    'grant_type=refresh_token'
      || '&refresh_token=' || extensions.urlencode(v_rt)
      || '&client_id='     || extensions.urlencode(v_cid)
      || '&client_secret=' || extensions.urlencode(v_csec)
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_access := v_body->>'access_token';
    v_new_rt := v_body->>'refresh_token';
    v_expin  := coalesce((v_body->>'expires_in')::bigint, 14400);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    if v_new_rt is not null and v_new_rt <> '' then
      perform vault.update_secret(v_rt_id, v_new_rt);
    end if;

    update public.tiny_oauth_state
       set access_token = v_access,
           token_type   = v_body->>'token_type',
           scope        = v_body->>'scope',
           expires_at   = v_new_exp,
           refreshed_at = now(),
           updated_at   = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('tiny_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('refreshed', true, 'valid', true, 'expires_at', v_new_exp);
  end if;

  if v_body ? 'error' and v_body->>'error' = 'invalid_grant' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('tiny_brigide', v_status, false,
            'INVALID_GRANT: cadeia de refresh quebrada — requer reautorizacao manual do app TINY');
    return jsonb_build_object('refreshed', false, 'valid', false,
                              'error', 'invalid_grant', 'action', 'reautorizacao_manual_necessaria');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('tiny_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false,
                            'error', 'refresh_failed', 'http_status', v_status);
end $$;

-- Permissões: só service_role
revoke all on function public.tiny_token_check(text) from public, anon, authenticated;
revoke all on function public.tiny_get_state() from public, anon, authenticated;
revoke all on function public.tiny_exchange_code(text, text) from public, anon, authenticated;
revoke all on function public.tiny_refresh_token(boolean) from public, anon, authenticated;
grant execute on function public.tiny_token_check(text) to service_role;
grant execute on function public.tiny_get_state() to service_role;
grant execute on function public.tiny_exchange_code(text, text) to service_role;
grant execute on function public.tiny_refresh_token(boolean) to service_role;
