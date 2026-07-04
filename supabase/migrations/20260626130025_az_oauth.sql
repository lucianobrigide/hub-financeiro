-- Custódia de token Amazon SP-API (LWA), clone do padrão ML adaptado:
-- LWA não rotaciona o refresh_token (vive no Vault: az_lwa_client_id/_secret,
-- az_refresh_token, az_token_key, az_authorize_date); access_token ~1h cacheado
-- em az_oauth_state (singleton id=1). Sem segredos neste arquivo.
create table if not exists public.az_oauth_state (
  id            int primary key check (id = 1),
  access_token  text,
  token_type    text,
  expires_at    timestamptz,
  refreshed_at  timestamptz,
  seller_id     text,
  updated_at    timestamptz not null default now()
);
alter table public.az_oauth_state enable row level security;
insert into public.az_oauth_state (id) values (1) on conflict (id) do nothing;

create or replace function public.az_token_check(p_key text)
returns boolean language plpgsql security definer
set search_path to 'public','vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected from vault.decrypted_secrets where name = 'az_token_key';
  if v_expected is null or v_expected = '' then return false; end if;
  return p_key = v_expected;
end $$;

create or replace function public.az_get_state()
returns table(access_token text, expires_at timestamptz)
language sql security definer set search_path to 'public'
as $$ select access_token, expires_at from public.az_oauth_state where id = 1; $$;

create or replace function public.az_refresh_token(p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_margin  interval := case when p_force then interval '2 minutes' else interval '10 minutes' end;
  v_exp     timestamptz;
  v_cid text; v_csec text; v_rt text;
  v_status int; v_raw text; v_body jsonb;
  v_access text; v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982732);

  select expires_at into v_exp from public.az_oauth_state where id = 1;
  if not p_force and v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true, 'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'az_lwa_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'az_lwa_client_secret';
  select decrypted_secret into v_rt   from vault.decrypted_secrets where name = 'az_refresh_token';
  if v_cid is null or v_csec is null or v_rt is null or v_rt = '' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('amazon_brigide', null, false, 'credenciais az_* ausentes no Vault');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
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
    update public.az_oauth_state
       set access_token = v_access, token_type = v_body->>'token_type',
           expires_at = v_new_exp, refreshed_at = now(), updated_at = now()
     where id = 1;
    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('amazon_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);
    return jsonb_build_object('refreshed', true, 'valid', true, 'expires_at', v_new_exp);
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('amazon_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_failed', 'http_status', v_status);
end $$;

revoke all on function public.az_token_check(text) from public, anon, authenticated;
revoke all on function public.az_get_state() from public, anon, authenticated;
revoke all on function public.az_refresh_token(boolean) from public, anon, authenticated;
grant execute on function public.az_token_check(text) to service_role;
grant execute on function public.az_get_state() to service_role;
grant execute on function public.az_refresh_token(boolean) to service_role;
