-- Custódia de token Shopee — OAuth2 com HMAC-SHA256, clone do padrão ML/TINY.
-- Access token 4h, refresh token 30 dias e ROTACIONA (regravar no Vault a cada uso).
-- Segredos no Vault: shopee_partner_id, shopee_partner_key, shopee_refresh_token, shopee_token_key.
-- Nenhum segredo neste arquivo.

-- Estado não-sensível (singleton id=1)
create table if not exists public.shopee_oauth_state (
  id                 int primary key check (id = 1),
  shop_id            bigint,
  access_token       text,
  expires_at         timestamptz,
  refresh_expires_at timestamptz,
  refreshed_at       timestamptz,
  updated_at         timestamptz not null default now()
);
alter table public.shopee_oauth_state enable row level security;
insert into public.shopee_oauth_state (id) values (1) on conflict (id) do nothing;

-- Valida x-api-key contra Vault (fail-closed)
create or replace function public.shopee_token_check(p_key text)
returns boolean language plpgsql security definer
set search_path to 'public', 'vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected
    from vault.decrypted_secrets where name = 'shopee_token_key';
  if v_expected is null or v_expected = '' then return false; end if;
  return p_key = v_expected;
end $$;

-- Leitura do estado (sem segredos)
create or replace function public.shopee_get_state()
returns table(access_token text, shop_id bigint, expires_at timestamptz)
language sql security definer set search_path to 'public'
as $$ select access_token, shop_id, expires_at from public.shopee_oauth_state where id = 1; $$;

-- Gera URL de autorização assinada (HMAC-SHA256) para o lojista clicar.
-- Base string (public API): partner_id + path + timestamp
create or replace function public.shopee_auth_url()
returns text language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_pid  text;
  v_pkey text;
  v_ts   bigint;
  v_path text := '/api/v2/shop/auth_partner';
  v_redirect text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/shopee-oauth-callback';
  v_base text;
  v_sign text;
begin
  select decrypted_secret into v_pid  from vault.decrypted_secrets where name = 'shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name = 'shopee_partner_key';

  if v_pid is null or v_pkey is null then
    raise exception 'shopee_partner_id ou shopee_partner_key ausentes no Vault';
  end if;

  v_ts   := extract(epoch from now())::bigint;
  v_base := v_pid || v_path || v_ts::text;
  v_sign := encode(extensions.hmac(v_base, v_pkey, 'sha256'), 'hex');

  return 'https://partner.shopeemobile.com' || v_path
    || '?partner_id=' || v_pid
    || '&redirect='   || extensions.urlencode(v_redirect)
    || '&sign='       || v_sign
    || '&timestamp='  || v_ts::text;
end $$;

-- Troca authorization code por tokens (chamado pelo callback Edge).
-- Partner_key NUNCA sai do PG — a chamada HTTP à Shopee acontece aqui dentro.
-- Base string (public API): partner_id + path + timestamp
create or replace function public.shopee_exchange_code(p_code text, p_shop_id bigint)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_pid text; v_pkey text; v_rt_id uuid;
  v_ts bigint;
  v_path text := '/api/v2/auth/token/get';
  v_base text; v_sign text;
  v_url text; v_req_body text;
  v_status int; v_raw text; v_body jsonb;
  v_expin bigint; v_new_exp timestamptz;
begin
  select decrypted_secret into v_pid  from vault.decrypted_secrets where name = 'shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name = 'shopee_partner_key';
  select id              into v_rt_id from vault.secrets          where name = 'shopee_refresh_token';

  if v_pid is null or v_pkey is null then
    return jsonb_build_object('ok', false, 'error', 'missing_credentials');
  end if;

  v_ts   := extract(epoch from now())::bigint;
  v_base := v_pid || v_path || v_ts::text;
  v_sign := encode(extensions.hmac(v_base, v_pkey, 'sha256'), 'hex');

  v_url := 'https://partner.shopeemobile.com' || v_path
    || '?partner_id=' || v_pid
    || '&timestamp='  || v_ts::text
    || '&sign='       || v_sign;

  v_req_body := jsonb_build_object(
    'code',       p_code,
    'shop_id',    p_shop_id,
    'partner_id', v_pid::bigint
  )::text;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST', v_url,
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/json', v_req_body
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_expin  := coalesce((v_body->>'expire_in')::bigint, 14400);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    if v_body ? 'refresh_token' and (v_body->>'refresh_token') <> '' then
      perform vault.update_secret(v_rt_id, v_body->>'refresh_token');
    end if;

    update public.shopee_oauth_state
       set shop_id            = p_shop_id,
           access_token       = v_body->>'access_token',
           expires_at         = v_new_exp,
           refresh_expires_at = now() + interval '30 days',
           refreshed_at       = now(),
           updated_at         = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('shopee_brigide', v_status, true, 'initial_auth_ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('ok', true, 'expires_in', v_expin, 'shop_id', p_shop_id);
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('shopee_brigide', v_status, false, 'exchange_failed: ' || left(coalesce(v_raw, 'sem corpo'), 500));

  return jsonb_build_object('ok', false, 'error', 'token_exchange_failed', 'http_status', v_status,
                            'detail', coalesce(v_body->>'message', v_body->>'error', left(v_raw, 200)));
end $$;

-- Refresh atômico sob advisory lock (Shopee rotaciona: regrava refresh_token novo).
-- Base string (public API): partner_id + path + timestamp
create or replace function public.shopee_refresh_token(p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_margin  interval := case when p_force then interval '5 minutes' else interval '30 minutes' end;
  v_exp     timestamptz;
  v_shop_id bigint;
  v_pid text; v_pkey text; v_rt text; v_rt_id uuid;
  v_ts bigint;
  v_path text := '/api/v2/auth/access_token/get';
  v_base text; v_sign text;
  v_url text; v_req_body text;
  v_status int; v_raw text; v_body jsonb;
  v_access text; v_new_rt text; v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982735);

  select expires_at, shop_id into v_exp, v_shop_id
    from public.shopee_oauth_state where id = 1;

  if not p_force and v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true, 'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  if v_shop_id is null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('shopee_brigide', null, false, 'shop_id nulo — autorize o app primeiro');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'shop_not_authorized');
  end if;

  select decrypted_secret into v_pid  from vault.decrypted_secrets where name = 'shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name = 'shopee_partner_key';
  select decrypted_secret into v_rt   from vault.decrypted_secrets where name = 'shopee_refresh_token';
  select id              into v_rt_id from vault.secrets          where name = 'shopee_refresh_token';

  if v_pid is null or v_pkey is null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('shopee_brigide', null, false, 'shopee_partner_id/shopee_partner_key ausentes no Vault');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
  end if;

  if v_rt is null or v_rt = '' or v_rt = '__PLACEHOLDER__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('shopee_brigide', null, false, 'shopee_refresh_token nao semeado (autorize o app primeiro)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded');
  end if;

  v_ts   := extract(epoch from now())::bigint;
  v_base := v_pid || v_path || v_ts::text;
  v_sign := encode(extensions.hmac(v_base, v_pkey, 'sha256'), 'hex');

  v_url := 'https://partner.shopeemobile.com' || v_path
    || '?partner_id=' || v_pid
    || '&timestamp='  || v_ts::text
    || '&sign='       || v_sign;

  v_req_body := jsonb_build_object(
    'refresh_token', v_rt,
    'shop_id',       v_shop_id,
    'partner_id',    v_pid::bigint
  )::text;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST', v_url,
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/json', v_req_body
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_access := v_body->>'access_token';
    v_new_rt := v_body->>'refresh_token';
    v_expin  := coalesce((v_body->>'expire_in')::bigint, 14400);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    if v_new_rt is not null and v_new_rt <> '' then
      perform vault.update_secret(v_rt_id, v_new_rt);
    end if;

    update public.shopee_oauth_state
       set access_token       = v_access,
           expires_at         = v_new_exp,
           refresh_expires_at = now() + interval '30 days',
           refreshed_at       = now(),
           updated_at         = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('shopee_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('refreshed', true, 'valid', true, 'expires_at', v_new_exp);
  end if;

  if v_body is not null and (v_body ? 'error' or v_body ? 'message') then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('shopee_brigide', v_status, false,
            'REFRESH_FAILED: ' || coalesce(v_body->>'error', '') || ' ' || coalesce(v_body->>'message', ''));
    return jsonb_build_object('refreshed', false, 'valid', false,
                              'error', coalesce(v_body->>'error', v_body->>'message', 'unknown'),
                              'action', 'reautorizacao_manual_necessaria');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('shopee_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false,
                            'error', 'refresh_failed', 'http_status', v_status);
end $$;

-- Gera params assinados para chamadas à API Shopee (shop-level).
-- Base string (shop API): partner_id + path + timestamp + access_token + shop_id
create or replace function public.shopee_signed_params(p_path text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_pid text; v_pkey text;
  v_access text; v_shop_id bigint;
  v_ts bigint;
  v_base text; v_sign text;
begin
  select decrypted_secret into v_pid  from vault.decrypted_secrets where name = 'shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name = 'shopee_partner_key';
  select access_token, shop_id into v_access, v_shop_id
    from public.shopee_oauth_state where id = 1;

  if v_pid is null or v_pkey is null then
    return jsonb_build_object('error', 'missing_credentials');
  end if;
  if v_access is null or v_shop_id is null then
    return jsonb_build_object('error', 'not_authorized');
  end if;

  v_ts   := extract(epoch from now())::bigint;
  v_base := v_pid || p_path || v_ts::text || v_access || v_shop_id::text;
  v_sign := encode(extensions.hmac(v_base, v_pkey, 'sha256'), 'hex');

  return jsonb_build_object(
    'partner_id',   v_pid::bigint,
    'timestamp',    v_ts,
    'access_token', v_access,
    'shop_id',      v_shop_id,
    'sign',         v_sign
  );
end $$;

-- Permissões: só service_role
revoke all on function public.shopee_token_check(text)          from public, anon, authenticated;
revoke all on function public.shopee_get_state()                from public, anon, authenticated;
revoke all on function public.shopee_auth_url()                 from public, anon, authenticated;
revoke all on function public.shopee_exchange_code(text, bigint) from public, anon, authenticated;
revoke all on function public.shopee_refresh_token(boolean)     from public, anon, authenticated;
revoke all on function public.shopee_signed_params(text)        from public, anon, authenticated;
grant execute on function public.shopee_token_check(text)          to service_role;
grant execute on function public.shopee_get_state()                to service_role;
grant execute on function public.shopee_auth_url()                 to service_role;
grant execute on function public.shopee_exchange_code(text, bigint) to service_role;
grant execute on function public.shopee_refresh_token(boolean)     to service_role;
grant execute on function public.shopee_signed_params(text)        to service_role;
