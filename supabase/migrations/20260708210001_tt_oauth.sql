-- Custódia de token TikTok Shop — OAuth2 com HMAC-SHA256.
-- Access token ~7 dias (timestamp absoluto), refresh ~99 anos, ROTACIONA.
-- Signing: app_secret + path + sorted_params [+ body] + app_secret → HMAC-SHA256 → hex.
-- Params excluídos do sign: access_token (vai no header x-tts-access-token), sign.
-- Segredos no Vault: tt_app_key, tt_app_secret, tt_refresh_token, tt_token_key.
-- Nenhum segredo neste arquivo.

-- Estado não-sensível (singleton id=1)
create table if not exists public.tt_oauth_state (
  id                 int primary key check (id = 1),
  shop_cipher        text,
  seller_name        text,
  seller_region      text,
  open_id            text,
  access_token       text,
  expires_at         timestamptz,
  refresh_expires_at timestamptz,
  refreshed_at       timestamptz,
  updated_at         timestamptz not null default now()
);
alter table public.tt_oauth_state enable row level security;
insert into public.tt_oauth_state (id) values (1) on conflict (id) do nothing;

-- Valida x-api-key contra Vault (fail-closed)
create or replace function public.tt_token_check(p_key text)
returns boolean language plpgsql security definer
set search_path to 'public', 'vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected
    from vault.decrypted_secrets where name = 'tt_token_key';
  if v_expected is null or v_expected = '' then return false; end if;
  return p_key = v_expected;
end $$;

-- Leitura do estado (sem segredos)
create or replace function public.tt_get_state()
returns table(access_token text, shop_cipher text, expires_at timestamptz)
language sql security definer set search_path to 'public'
as $$ select access_token, shop_cipher, expires_at from public.tt_oauth_state where id = 1; $$;

-- Gera URL de autorização (sem signing)
create or replace function public.tt_auth_url()
returns text language plpgsql security definer
set search_path to 'public', 'vault'
as $$
declare v_app_key text;
begin
  select decrypted_secret into v_app_key
    from vault.decrypted_secrets where name = 'tt_app_key';
  if v_app_key is null then
    raise exception 'tt_app_key ausente no Vault';
  end if;
  return 'https://services.tiktokshop.com/open/authorize?app_key=' || v_app_key;
end $$;

-- Helper: HMAC-SHA256 no padrão TikTok Shop.
-- sign = hmac(app_secret + path + sorted(key1val1...) [+ body] + app_secret, app_secret) → hex
create or replace function public.tt_sign(
  p_path text, p_params jsonb, p_secret text, p_body text default null
) returns text language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
declare v_sorted text; v_input text;
begin
  select string_agg(kv.key || kv.value, '' order by kv.key)
  from jsonb_each_text(p_params) as kv
  into v_sorted;

  v_input := p_secret || p_path || coalesce(v_sorted, '')
             || coalesce(p_body, '') || p_secret;
  return encode(extensions.hmac(v_input, p_secret, 'sha256'), 'hex');
end $$;

-- Troca authorization code por tokens + busca shop_cipher.
-- GET https://auth.tiktok-shops.com/api/v2/token/get (sem signing — credentials na URL).
-- Depois busca shop_cipher via GET /authorization/202309/shops (signed, token no header).
create or replace function public.tt_exchange_code(p_code text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_app_key text; v_app_secret text; v_rt_id uuid;
  v_url text; v_status int; v_raw text; v_body jsonb; v_data jsonb;
  v_access text; v_rt text;
  v_new_exp timestamptz; v_rt_exp timestamptz;
  v_cipher text;
  v_shops_ts bigint; v_shops_sign text; v_shops_url text;
  v_shops_path text := '/authorization/202309/shops';
  v_shops_params jsonb;
  v_shops_status int; v_shops_raw text; v_shops_body jsonb;
  v_shops_resp extensions.http_response;
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name = 'tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name = 'tt_app_secret';
  select id              into v_rt_id       from vault.secrets          where name = 'tt_refresh_token';

  if v_app_key is null or v_app_secret is null then
    return jsonb_build_object('ok', false, 'error', 'missing_credentials');
  end if;

  v_url := 'https://auth.tiktok-shops.com/api/v2/token/get'
    || '?app_key='    || v_app_key
    || '&app_secret=' || v_app_secret
    || '&auth_code='  || p_code
    || '&grant_type=authorized_code';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select r.status, r.content into v_status, v_raw
  from extensions.http_get(v_url) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;
  v_data := v_body->'data';

  if v_status = 200 and v_body is not null and (v_body->>'code')::int = 0
     and v_data is not null and v_data ? 'access_token' then

    v_access := v_data->>'access_token';
    v_rt     := v_data->>'refresh_token';
    v_new_exp := to_timestamp((v_data->>'access_token_expire_in')::bigint);
    v_rt_exp  := to_timestamp((v_data->>'refresh_token_expire_in')::bigint);

    if v_rt is not null and v_rt <> '' then
      perform vault.update_secret(v_rt_id, v_rt);
    end if;

    update public.tt_oauth_state
       set access_token       = v_access,
           seller_name        = v_data->>'seller_name',
           seller_region      = v_data->>'seller_base_region',
           open_id            = v_data->>'open_id',
           expires_at         = v_new_exp,
           refresh_expires_at = v_rt_exp,
           refreshed_at       = now(),
           updated_at         = now()
     where id = 1;

    begin
      v_shops_ts     := extract(epoch from now())::bigint;
      v_shops_params := jsonb_build_object('app_key', v_app_key, 'timestamp', v_shops_ts::text);
      v_shops_sign   := public.tt_sign(v_shops_path, v_shops_params, v_app_secret);

      v_shops_url := 'https://open-api.tiktokglobalshop.com' || v_shops_path
        || '?app_key='   || v_app_key
        || '&timestamp=' || v_shops_ts::text
        || '&sign='      || v_shops_sign;

      select * into v_shops_resp
      from extensions.http((
        'GET',
        v_shops_url,
        array[extensions.http_header('x-tts-access-token', v_access)],
        null,
        null
      )::extensions.http_request);

      v_shops_status := v_shops_resp.status;
      v_shops_raw    := v_shops_resp.content;
      v_shops_body   := case when left(coalesce(v_shops_raw, ''), 1) = '{'
                              then v_shops_raw::jsonb else null end;

      if v_shops_status = 200 and v_shops_body is not null
         and (v_shops_body->>'code')::int = 0 then
        v_cipher := v_shops_body->'data'->'shops'->0->>'cipher';
        if v_cipher is not null then
          update public.tt_oauth_state set shop_cipher = v_cipher where id = 1;
        end if;
      end if;

      insert into public.oauth_refresh_log(conta, http_status, success, message)
      values ('tt_brigide', v_shops_status, v_shops_status = 200,
              'get_shops: HTTP ' || v_shops_status || ' | ' || left(coalesce(v_shops_raw, 'sem corpo'), 300));
    exception when others then
      insert into public.oauth_refresh_log(conta, http_status, success, message)
      values ('tt_brigide', null, false, 'get_shops_exception: ' || SQLERRM);
    end;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('tt_brigide', v_status, true,
            'initial_auth_ok' || coalesce(' | cipher=' || v_cipher, ' | cipher=pending'),
            extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('ok', true, 'expires_at', v_new_exp,
                              'seller_name', v_data->>'seller_name',
                              'shop_cipher', v_cipher);
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('tt_brigide', v_status, false,
          'exchange_failed: ' || left(coalesce(v_raw, 'sem corpo'), 500));

  return jsonb_build_object('ok', false, 'error', 'token_exchange_failed',
                            'http_status', v_status,
                            'detail', coalesce(v_data->>'message', v_body->>'message', left(v_raw, 200)));
end $$;

-- Refresh atômico sob advisory lock 421982736.
-- TikTok rotaciona refresh_token — regrava no Vault.
-- Margem default 2 dias (access ~7 dias); force usa 1 hora.
create or replace function public.tt_refresh_token(p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_margin interval := case when p_force then interval '1 hour' else interval '2 days' end;
  v_exp    timestamptz;
  v_app_key text; v_app_secret text; v_rt text; v_rt_id uuid;
  v_url text; v_status int; v_raw text; v_body jsonb; v_data jsonb;
  v_access text; v_new_rt text;
  v_new_exp timestamptz; v_rt_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982736);

  select expires_at into v_exp from public.tt_oauth_state where id = 1;

  if not p_force and v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true,
                              'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name = 'tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name = 'tt_app_secret';
  select decrypted_secret into v_rt         from vault.decrypted_secrets where name = 'tt_refresh_token';
  select id              into v_rt_id       from vault.secrets          where name = 'tt_refresh_token';

  if v_app_key is null or v_app_secret is null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('tt_brigide', null, false, 'tt_app_key/tt_app_secret ausentes no Vault');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
  end if;

  if v_rt is null or v_rt = '' or v_rt = '__PLACEHOLDER__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('tt_brigide', null, false, 'tt_refresh_token nao semeado (autorize o app primeiro)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded',
                              'action', 'reautorizacao_manual_necessaria');
  end if;

  v_url := 'https://auth.tiktok-shops.com/api/v2/token/refresh'
    || '?app_key='       || v_app_key
    || '&app_secret='    || v_app_secret
    || '&refresh_token=' || v_rt
    || '&grant_type=refresh_token';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select r.status, r.content into v_status, v_raw
  from extensions.http_get(v_url) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;
  v_data := v_body->'data';

  if v_status = 200 and v_body is not null and (v_body->>'code')::int = 0
     and v_data is not null and v_data ? 'access_token' then

    v_access := v_data->>'access_token';
    v_new_rt := v_data->>'refresh_token';
    v_new_exp := to_timestamp((v_data->>'access_token_expire_in')::bigint);
    v_rt_exp  := to_timestamp((v_data->>'refresh_token_expire_in')::bigint);

    if v_new_rt is not null and v_new_rt <> '' then
      perform vault.update_secret(v_rt_id, v_new_rt);
    end if;

    update public.tt_oauth_state
       set access_token       = v_access,
           expires_at         = v_new_exp,
           refresh_expires_at = v_rt_exp,
           refreshed_at       = now(),
           updated_at         = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('tt_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('refreshed', true, 'valid', true, 'expires_at', v_new_exp);
  end if;

  if v_body is not null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('tt_brigide', v_status, false,
            'REFRESH_FAILED: ' || coalesce(v_body->>'message', '') || ' '
            || coalesce(v_data->>'message', ''));
    return jsonb_build_object('refreshed', false, 'valid', false,
                              'error', coalesce(v_data->>'message', v_body->>'message', 'unknown'),
                              'action', 'reautorizacao_manual_necessaria');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('tt_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false,
                            'error', 'refresh_failed', 'http_status', v_status);
end $$;

-- Gera params assinados para chamadas à API TikTok Shop (GET).
-- shop_cipher NÃO auto-incluído; caller passa via p_extra quando o endpoint exige.
-- Retorna shop_cipher como campo separado pra conveniência.
create or replace function public.tt_signed_params(p_path text, p_extra jsonb default '{}')
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_app_key text; v_app_secret text;
  v_access text; v_cipher text;
  v_ts bigint;
  v_params jsonb;
  v_sign text;
  v_qs text;
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name = 'tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name = 'tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher
    from public.tt_oauth_state where id = 1;

  if v_app_key is null or v_app_secret is null then
    return jsonb_build_object('error', 'missing_credentials');
  end if;
  if v_access is null then
    return jsonb_build_object('error', 'not_authorized');
  end if;

  v_ts := extract(epoch from now())::bigint;

  v_params := jsonb_build_object('app_key', v_app_key, 'timestamp', v_ts::text);
  v_params := v_params || p_extra;

  v_sign := public.tt_sign(p_path, v_params, v_app_secret);

  select string_agg(kv.key || kv.value, '&' order by kv.key)
  from jsonb_each_text(v_params) as kv
  into v_qs;

  v_qs := v_qs || '&sign=' || v_sign;

  return jsonb_build_object(
    'base_url',     'https://open-api.tiktokglobalshop.com',
    'path',         p_path,
    'query_string', v_qs,
    'full_url',     'https://open-api.tiktokglobalshop.com' || p_path || '?' || v_qs,
    'access_token', v_access,
    'shop_cipher',  v_cipher,
    'headers',      jsonb_build_object('x-tts-access-token', v_access)
  );
end $$;

-- Permissões: só service_role
revoke all on function public.tt_token_check(text)              from public, anon, authenticated;
revoke all on function public.tt_get_state()                    from public, anon, authenticated;
revoke all on function public.tt_auth_url()                     from public, anon, authenticated;
revoke all on function public.tt_sign(text, jsonb, text, text)  from public, anon, authenticated;
revoke all on function public.tt_exchange_code(text)            from public, anon, authenticated;
revoke all on function public.tt_refresh_token(boolean)         from public, anon, authenticated;
revoke all on function public.tt_signed_params(text, jsonb)     from public, anon, authenticated;
grant execute on function public.tt_token_check(text)              to service_role;
grant execute on function public.tt_get_state()                    to service_role;
grant execute on function public.tt_auth_url()                     to service_role;
grant execute on function public.tt_sign(text, jsonb, text, text)  to service_role;
grant execute on function public.tt_exchange_code(text)            to service_role;
grant execute on function public.tt_refresh_token(boolean)         to service_role;
grant execute on function public.tt_signed_params(text, jsonb)     to service_role;
