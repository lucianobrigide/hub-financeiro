-- MAGALU MVP — fluxo OAuth2 real (id.magalu.com).
-- Descoberta: a API Key do ID Magalu NAO acessa dados de seller diretamente (401 em todos
-- os formatos, prod e HMG); ela apenas cria/gerencia clients. O client OAuth foi criado via
-- IDM CLI ("Hub Financeiro Brigide", UUID em magalu_oauth_state.client_uuid). Dados exigem
-- access_token (2h) + refresh_token (6 meses, USO UNICO) — padrao Tiny.
-- Segredos em vault.secrets: magalu_api_key, magalu_api_key_secret, magalu_client_id,
-- magalu_client_secret, magalu_refresh_token, magalu_token_key.

alter table public.magalu_oauth_state
  add column access_token text,
  add column token_type   text,
  add column scope        text,
  add column expires_at   timestamptz;

comment on table public.magalu_oauth_state is
  'Estado do OAuth MAGALU (ID Magalu). access_token (2h) fica aqui; refresh_token (6 meses, uso unico) vive em vault.secrets (magalu_refresh_token), client_id/secret idem. API Key (vault: magalu_api_key) so serve para criar/gerenciar o client OAuth. Linha unica id=1.';

-- util interno: upsert de segredo no Vault
create or replace function public.magalu_vault_upsert(p_name text, p_value text, p_desc text default null)
returns void
language plpgsql security definer set search_path to 'public', 'vault'
as $$
declare v_id uuid;
begin
  select id into v_id from vault.secrets where name = p_name;
  if v_id is null then
    perform vault.create_secret(p_value, p_name, coalesce(p_desc, p_name));
  else
    perform vault.update_secret(v_id, p_value);
  end if;
end $$;

-- cria o client OAuth2 na Magalu usando a API Key (x-api-key)
-- (caminho Acelera/integracommerce — retornou 401 com a API Key atual; mantido para referência.
--  O client em uso foi criado via IDM CLI.)
create or replace function public.magalu_criar_client(
  p_name text default 'Hub Financeiro Brigide',
  p_redirect_uri text default 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/magalu-oauth-callback',
  p_description text default 'Integracao propria Essenza di Chef / Brigide — leitura de pedidos e financeiro',
  p_own boolean default true
)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_key text; v_status int; v_raw text; v_body jsonb;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'magalu_api_key';
  if v_key is null or v_key = '' then
    return jsonb_build_object('ok', false, 'error', 'magalu_api_key_ausente_no_vault');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    'https://in.integracommerce.com.br/api/v1/clients',
    array[ extensions.http_header('x-api-key', v_key),
           extensions.http_header('Accept', 'application/json') ],
    'application/json',
    jsonb_build_object(
      'name', p_name,
      'description', p_description,
      'redirect_uri', p_redirect_uri,
      'privacy_policy_url', 'https://www.brigidestore.com.br',
      'service_term_url',   'https://www.brigidestore.com.br',
      'own_integration', p_own
    )::text
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'client_id' then
    perform public.magalu_vault_upsert('magalu_client_id',
      v_body->>'client_id', 'client_id OAuth2 MAGALU (id.magalu.com)');
    perform public.magalu_vault_upsert('magalu_client_secret',
      coalesce(v_body->>'client_secret', v_body->>'secret_id'),
      'client_secret OAuth2 MAGALU (id.magalu.com)');
    update public.magalu_oauth_state set updated_at = now() where id = 1;
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('magalu_brigide', v_status, true, 'client_criado | redirect=' || p_redirect_uri);
    return jsonb_build_object('ok', true, 'hint', 'client_id/client_secret gravados no Vault');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('magalu_brigide', v_status, false, 'criar_client_falhou: ' || left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('ok', false, 'error', 'criar_client_falhou',
    'http_status', v_status, 'detail', left(coalesce(v_raw, ''), 300));
end $$;

-- URL de consentimento para o seller (Luciano) autorizar
create or replace function public.magalu_auth_url(
  p_scope text default 'open:order-order-seller:read open:order-delivery-seller:read open:order-invoice-seller:read open:portfolio-skus-seller:read'
)
returns text
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare v_cid text; v_redirect text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/magalu-oauth-callback';
begin
  select decrypted_secret into v_cid from vault.decrypted_secrets where name = 'magalu_client_id';
  if v_cid is null then return null; end if;
  return 'https://id.magalu.com/login'
      || '?client_id='    || extensions.urlencode(v_cid)
      || '&redirect_uri=' || extensions.urlencode(v_redirect)
      || '&scope='        || extensions.urlencode(p_scope)
      || '&response_type=code&choose_tenants=true&state=hubfin';
end $$;

-- troca o authorization code por tokens
create or replace function public.magalu_exchange_code(p_code text, p_redirect_uri text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_cid text; v_csec text;
  v_status int; v_raw text; v_body jsonb;
  v_expin bigint; v_new_exp timestamptz;
begin
  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'magalu_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'magalu_client_secret';

  if v_cid is null or v_csec is null then
    return jsonb_build_object('ok', false, 'error', 'missing_credentials',
      'hint', 'rode magalu_criar_client() primeiro');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    'https://id.magalu.com/oauth/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/json',
    jsonb_build_object(
      'grant_type', 'authorization_code',
      'client_id', v_cid,
      'client_secret', v_csec,
      'redirect_uri', p_redirect_uri,
      'code', p_code
    )::text
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_expin  := coalesce((v_body->>'expires_in')::bigint, 7200);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    if v_body ? 'refresh_token' and (v_body->>'refresh_token') <> '' then
      perform public.magalu_vault_upsert('magalu_refresh_token',
        v_body->>'refresh_token', 'refresh_token OAuth2 MAGALU (uso unico, 6 meses)');
    end if;

    update public.magalu_oauth_state
       set access_token  = v_body->>'access_token',
           token_type    = v_body->>'token_type',
           scope         = v_body->>'scope',
           expires_at    = v_new_exp,
           authorized_at = now(),
           refreshed_at  = now(),
           updated_at    = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('magalu_brigide', v_status, true, 'initial_auth_ok | scope=' || coalesce(v_body->>'scope',''),
            extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('ok', true, 'expires_in', v_expin, 'scope', v_body->>'scope');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('magalu_brigide', v_status, false, 'exchange_failed: ' || left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('ok', false, 'error', 'token_exchange_failed',
    'http_status', v_status, 'detail', left(coalesce(v_raw, ''), 300));
end $$;

-- refresh real (substitui o stub de credencial longa; versão final sem spam de log
-- na migration magalu_refresh_sem_spam_log)
create or replace function public.magalu_refresh_token(p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_margin  interval := case when p_force then interval '2 minutes' else interval '10 minutes' end;
  v_exp     timestamptz;
  v_cid text; v_csec text; v_rt text; v_rt_id uuid;
  v_status int; v_raw text; v_body jsonb;
  v_expin bigint; v_new_exp timestamptz;
begin
  perform pg_advisory_xact_lock(421982799);

  select expires_at into v_exp from public.magalu_oauth_state where id = 1;

  if not p_force and v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true, 'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'magalu_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'magalu_client_secret';
  select decrypted_secret into v_rt   from vault.decrypted_secrets where name = 'magalu_refresh_token';
  select id              into v_rt_id from vault.secrets          where name = 'magalu_refresh_token';

  if v_cid is null or v_csec is null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('magalu_brigide', null, false, 'magalu_client_id/secret ausentes no Vault (rode magalu_criar_client)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
  end if;

  if v_rt is null or v_rt = '' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('magalu_brigide', null, false, 'magalu_refresh_token nao semeado (seller precisa consentir via magalu_auth_url)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded',
      'action', 'consentimento_do_seller_necessario');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    'https://id.magalu.com/oauth/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/x-www-form-urlencoded',
    'grant_type=refresh_token'
      || '&refresh_token=' || extensions.urlencode(v_rt)
      || '&client_id='     || extensions.urlencode(v_cid)
      || '&client_secret=' || extensions.urlencode(v_csec)
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_expin  := coalesce((v_body->>'expires_in')::bigint, 7200);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    if v_body ? 'refresh_token' and (v_body->>'refresh_token') <> '' then
      perform vault.update_secret(v_rt_id, v_body->>'refresh_token');
    end if;

    update public.magalu_oauth_state
       set access_token = v_body->>'access_token',
           token_type   = v_body->>'token_type',
           scope        = coalesce(v_body->>'scope', scope),
           expires_at   = v_new_exp,
           refreshed_at = now(),
           updated_at   = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('magalu_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('refreshed', true, 'valid', true, 'expires_at', v_new_exp);
  end if;

  if v_body ? 'error' and v_body->>'error' = 'invalid_grant' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('magalu_brigide', v_status, false,
            'INVALID_GRANT: cadeia de refresh quebrada — requer novo consentimento do seller (magalu_auth_url)');
    return jsonb_build_object('refreshed', false, 'valid', false,
      'error', 'invalid_grant', 'action', 'reautorizacao_manual_necessaria');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('magalu_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false,
    'error', 'refresh_failed', 'http_status', v_status);
end $$;

-- leitura do access_token para o gateway edge (nunca exposto a anon/authenticated)
create or replace function public.magalu_get_token()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_row public.magalu_oauth_state;
begin
  select * into v_row from public.magalu_oauth_state where id = 1;
  return jsonb_build_object(
    'access_token', v_row.access_token,
    'token_type',   coalesce(v_row.token_type, 'Bearer'),
    'expires_at',   v_row.expires_at,
    'tenant_id',    v_row.tenant_id,
    'scope',        v_row.scope
  );
end $$;

-- helper de chamada autenticada: garante token valido e usa Bearer
drop function if exists public.magalu_api_get(text, boolean);
drop function if exists public.magalu_api_get(text, text);
create or replace function public.magalu_api_get(p_path text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_tok text; v_tenant text; v_base text;
  v_headers extensions.http_header[];
  v_resp extensions.http_response;
  v_chk jsonb;
begin
  v_chk := public.magalu_refresh_token(false);
  if coalesce((v_chk->>'valid')::boolean, false) is not true then
    return jsonb_build_object('status', 0, 'error', 'token_invalido', 'detail', v_chk);
  end if;

  select access_token, tenant_id, base_url into v_tok, v_tenant, v_base
    from public.magalu_oauth_state where id = 1;

  v_headers := array[
    extensions.http_header('Authorization', 'Bearer ' || v_tok),
    extensions.http_header('Accept', 'application/json')
  ];
  if v_tenant is not null then
    v_headers := v_headers || extensions.http_header('X-TENANT-ID', v_tenant);
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  select * into v_resp from extensions.http((
    'GET', v_base || p_path, v_headers, null, null
  )::extensions.http_request);

  return jsonb_build_object(
    'status', v_resp.status,
    'body', case when left(coalesce(v_resp.content, ''), 1) in ('{', '[')
                 then v_resp.content::jsonb
                 else to_jsonb(left(coalesce(v_resp.content, ''), 1000)) end
  );
end $$;

revoke all on function public.magalu_vault_upsert(text, text, text) from anon, authenticated;
revoke all on function public.magalu_criar_client(text, text, text, boolean) from anon, authenticated;
revoke all on function public.magalu_auth_url(text) from anon, authenticated;
revoke all on function public.magalu_exchange_code(text, text) from anon, authenticated;
revoke all on function public.magalu_refresh_token(boolean) from anon, authenticated;
revoke all on function public.magalu_get_token() from anon, authenticated;
revoke all on function public.magalu_api_get(text) from anon, authenticated;
