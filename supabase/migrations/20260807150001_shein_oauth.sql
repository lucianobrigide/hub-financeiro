-- Custódia de credenciais SHEIN Open Platform — assinatura HMAC-SHA256, SEM refresh token.
-- Modelo SHEIN (≠ OAuth dos demais canais):
--   appid + appSecretKey (fixos, da app) → seller autoriza a app → tempToken (curto, uso único)
--   → POST /open-api/auth/get-by-token (assinado no modo APP: appid+appSecretKey)
--   → openKeyId + secretKey de LONGA DURAÇÃO (não expiram, não rotacionam).
-- "Refresh" não existe: shein_refresh_token() só valida a custódia (nada estimado, log honesto).
-- Assinatura (fonte: SDK oficial sheinsight/open-sdk-java, SignUtil/AesUtil):
--   signString = <key_id> || '&' || <timestamp_ms> || '&' || <path>
--   randomKey  = 5 chars; chave HMAC = <secret> || randomKey
--   x-lt-signature = randomKey || base64( hex( hmac_sha256(signString) ) )
--   (base64 do PG insere \n a cada 76 chars — tem que remover.)
--   Modo APP (get-by-token): key_id = appid, secret = appSecretKey, header x-lt-appid.
--   Modo OPEN_KEY (demais APIs): key_id = openKeyId, secret = secretKey, header x-lt-openKeyId.
-- secretKey vem CRIPTOGRAFADO no get-by-token: AES-128-CBC, chave = primeiros 16 bytes
--   do appSecretKey, IV fixo 'space-station-de', PKCS5, conteúdo em base64.
-- Domínio: https://openapi.sheincorp.com
-- Segredos no Vault: shein_app_id, shein_app_secret, shein_secret_key, shein_token_key.
-- Nenhum segredo neste arquivo.

-- Estado não-sensível (singleton id=1). openKeyId fica aqui (análogo ao access_token
-- dos outros canais); o secretKey fica SÓ no Vault.
create table if not exists public.shein_oauth_state (
  id            int primary key check (id = 1),
  open_key_id   text,
  supplier_id   text,
  supplier_name text,
  authorized_at timestamptz,
  refreshed_at  timestamptz,
  updated_at    timestamptz not null default now()
);
comment on table public.shein_oauth_state is
  'Estado nao-sensivel da credencial SHEIN. secretKey NAO fica aqui — vive em vault.secrets (shein_secret_key). Sem refresh token: openKeyId/secretKey sao de longa duracao. Linha unica id=1.';
alter table public.shein_oauth_state enable row level security;
insert into public.shein_oauth_state (id) values (1) on conflict (id) do nothing;

-- Valida x-api-key contra Vault (fail-closed)
create or replace function public.shein_token_check(p_key text)
returns boolean language plpgsql security definer
set search_path to 'public', 'vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected
    from vault.decrypted_secrets where name = 'shein_token_key';
  if v_expected is null or v_expected = '' then return false; end if;
  return p_key = v_expected;
end $$;

-- Leitura do estado (sem segredos)
create or replace function public.shein_get_state()
returns table(open_key_id text, supplier_id text, authorized_at timestamptz)
language sql security definer set search_path to 'public'
as $$ select open_key_id, supplier_id, authorized_at from public.shein_oauth_state where id = 1; $$;

-- Helper: assinatura SHEIN (modo APP ou OPEN_KEY conforme os argumentos).
-- randomKey = 5 primeiros chars de um uuid (hex); replace tira os \n do base64 do PG.
create or replace function public.shein_sign(
  p_key_id text, p_secret text, p_path text, p_ts text
) returns text language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
declare v_random text; v_hex text;
begin
  v_random := substr(gen_random_uuid()::text, 1, 5);
  v_hex := encode(extensions.hmac(
    convert_to(p_key_id || '&' || p_ts || '&' || p_path, 'UTF8'),
    convert_to(p_secret || v_random, 'UTF8'),
    'sha256'), 'hex');
  return v_random || replace(encode(convert_to(v_hex, 'UTF8'), 'base64'), E'\n', '');
end $$;

-- Headers assinados para chamar a API SHEIN (modo OPEN_KEY).
-- Timestamp em MILISSEGUNDOS (regra da SHEIN, ≠ segundos dos outros canais).
create or replace function public.shein_signed_headers(p_path text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_key_id text; v_secret text; v_ts text; v_sig text;
begin
  select open_key_id into v_key_id from public.shein_oauth_state where id = 1;
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'shein_secret_key';

  if v_key_id is null or v_secret is null or v_secret in ('', '__PLACEHOLDER__') then
    return jsonb_build_object('error', 'not_authorized',
      'hint', 'Autorize a app na SHEIN e rode shein_exchange_token(tempToken).');
  end if;

  v_ts  := (extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  v_sig := public.shein_sign(v_key_id, v_secret, p_path, v_ts);

  return jsonb_build_object(
    'base_url', 'https://openapi.sheincorp.com',
    'path',     p_path,
    'full_url', 'https://openapi.sheincorp.com' || p_path,
    'headers',  jsonb_build_object(
      'x-lt-openKeyId', v_key_id,
      'x-lt-timestamp', v_ts,
      'x-lt-signature', v_sig,
      'Content-Type',   'application/json;charset=UTF-8'
    )
  );
end $$;

-- Troca o tempToken (da autorização do seller) por openKeyId + secretKey.
-- POST /open-api/auth/get-by-token, assinado no modo APP (x-lt-appid).
-- Decripta o secretKey (AES-128-CBC, chave = 16 primeiros bytes do appSecret,
-- IV 'space-station-de') e guarda no Vault; openKeyId vai pro estado.
create or replace function public.shein_exchange_token(p_temp_token text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_appid text; v_app_secret text; v_sk_id uuid;
  v_ts text; v_sig text;
  v_status int; v_raw text; v_body jsonb; v_info jsonb;
  v_code text;
  v_open_key text; v_secret_enc text; v_secret text;
  v_resp extensions.http_response;
begin
  select decrypted_secret into v_appid      from vault.decrypted_secrets where name = 'shein_app_id';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name = 'shein_app_secret';
  select id               into v_sk_id      from vault.secrets           where name = 'shein_secret_key';

  if v_appid is null or v_app_secret is null then
    return jsonb_build_object('ok', false, 'error', 'missing_credentials',
      'hint', 'shein_app_id/shein_app_secret ausentes no Vault');
  end if;
  if p_temp_token is null or p_temp_token = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_temp_token');
  end if;

  v_ts  := (extract(epoch from clock_timestamp()) * 1000)::bigint::text;
  v_sig := public.shein_sign(v_appid, v_app_secret, '/open-api/auth/get-by-token', v_ts);

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select * into v_resp from extensions.http((
    'POST',
    'https://openapi.sheincorp.com/open-api/auth/get-by-token',
    array[
      extensions.http_header('x-lt-appid', v_appid),
      extensions.http_header('x-lt-timestamp', v_ts),
      extensions.http_header('x-lt-signature', v_sig)
    ],
    'application/json',
    jsonb_build_object('tempToken', p_temp_token)::text
  )::extensions.http_request);

  v_status := v_resp.status;
  v_raw    := v_resp.content;
  v_body   := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;
  v_code   := v_body->>'code';
  v_info   := v_body->'info';

  if v_status = 200 and v_code = '0' and v_info ? 'openKeyId' then
    v_open_key   := v_info->>'openKeyId';
    v_secret_enc := v_info->>'secretKey';

    -- decripta o secretKey (vem base64 + AES-128-CBC com IV fixo)
    begin
      v_secret := convert_from(extensions.decrypt_iv(
        decode(v_secret_enc, 'base64'),
        substring(convert_to(v_app_secret, 'UTF8') from 1 for 16),
        convert_to('space-station-de', 'UTF8'),
        'aes-cbc/pad:pkcs'), 'UTF8');
    exception when others then
      insert into public.oauth_refresh_log(conta, http_status, success, message)
      values ('shein_brigide', v_status, false, 'decrypt_secret_falhou: ' || SQLERRM);
      return jsonb_build_object('ok', false, 'error', 'decrypt_failed', 'detail', SQLERRM);
    end;

    perform vault.update_secret(v_sk_id, v_secret);

    update public.shein_oauth_state
       set open_key_id   = v_open_key,
           supplier_id   = coalesce(v_info->>'supplierId', v_info->>'supplier_id'),
           supplier_name = coalesce(v_info->>'supplierName', v_info->>'supplier_name'),
           authorized_at = now(),
           refreshed_at  = now(),
           updated_at    = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('shein_brigide', v_status, true,
            'exchange_ok | openKeyId=' || v_open_key || ' (secretKey no Vault; longa duracao)');

    return jsonb_build_object('ok', true, 'open_key_id', v_open_key,
      'hint', 'openKeyId em shein_oauth_state, secretKey no Vault — sem expiracao/refresh');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('shein_brigide', v_status, false,
          'exchange_falhou: ' || left(coalesce(v_raw, 'sem corpo'), 500));

  return jsonb_build_object('ok', false, 'error', 'exchange_failed',
    'http_status', v_status,
    'detail', coalesce(v_body->>'msg', left(v_raw, 200)));
end $$;

-- "Refresh" honesto: a SHEIN NÃO tem refresh token — openKeyId/secretKey não expiram.
-- Esta função só valida a custódia (semeado? autorizado?) e devolve o status,
-- para manter o contrato dos Edge gateways (*-token) igual aos demais canais.
create or replace function public.shein_refresh_token(p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public', 'vault'
as $$
declare v_key_id text; v_secret text;
begin
  select open_key_id into v_key_id from public.shein_oauth_state where id = 1;
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'shein_secret_key';

  if v_key_id is null or v_secret is null or v_secret in ('', '__PLACEHOLDER__') then
    return jsonb_build_object('refreshed', false, 'valid', false,
      'error', 'shein_nao_autorizado',
      'action', 'autorizar_app_shein_e_rodar_shein_exchange_token');
  end if;

  return jsonb_build_object('refreshed', false, 'valid', true,
    'reason', 'credencial_longa_duracao_sem_expiracao');
end $$;

-- ── Dados (MVP): pedidos + itens. Réguas finas (status/competência/deduções)
-- ficam para a fase 100%, quando a ingestão real definir o shape — por isso o raw jsonb.
create table if not exists public.shein_pedidos (
  order_no     text primary key,
  order_status text,
  create_time  timestamptz,
  update_time  timestamptz,
  currency     text,
  valor_total  numeric(14,2),
  raw          jsonb,
  inserted_at  timestamptz not null default now()
);
comment on table public.shein_pedidos is
  'Pedidos SHEIN (MVP — shape minimo + raw; regua de status/competencia fecha na fase 100% com a ingestao real).';
alter table public.shein_pedidos enable row level security;

create table if not exists public.shein_itens (
  order_no   text not null,
  linha      int  not null,
  sku        text,
  goods_name text,
  quantity   int,
  unit_price numeric(14,2),
  raw        jsonb,
  primary key (order_no, linha)
);
alter table public.shein_itens enable row level security;

-- Bruta do mês (card). Competência create_time BRT; régua de status MVP = exclui
-- cancelado/não-pago (refinar na fase 100% com os status reais da API).
create or replace function public.shein_faturamento(p_month text)
returns jsonb language sql stable security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'faturamento_bruto', coalesce(sum(valor_total), 0),
    'total_pedidos',     count(*)
  )
  from public.shein_pedidos
  where to_char(create_time at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and coalesce(order_status, '') not in ('CANCELLED','CANCELED','UNPAID','REFUNDED');
$$;

-- CMV do mês (card) — mesma mecânica do sp_cmv: SKU × ml_custo_produto com
-- vigência ancorada na competência do pedido (create_time BRT).
create or replace function public.shein_cmv(p_month text)
returns jsonb language sql stable security definer
set search_path to 'public', 'extensions'
as $$
  select jsonb_build_object(
    'cmv_total',       coalesce(sum(c.custo * i.quantity), 0),
    'itens_com_custo', count(*) filter (where c.custo is not null),
    'itens_total',     count(*)
  )
  from public.shein_itens i
  join public.shein_pedidos p on p.order_no = i.order_no
  left join public.ml_custo_produto c
    on c.sku = unaccent(i.sku)
   and (p.create_time at time zone 'America/Sao_Paulo')::date >= c.vigencia_inicio
   and (c.vigencia_fim is null or (p.create_time at time zone 'America/Sao_Paulo')::date < c.vigencia_fim)
  where to_char(p.create_time at time zone 'America/Sao_Paulo', 'YYYY-MM') = p_month
    and coalesce(p.order_status, '') not in ('CANCELLED','CANCELED','UNPAID','REFUNDED');
$$;

-- Permissões: só service_role
revoke all on function public.shein_token_check(text)        from public, anon, authenticated;
revoke all on function public.shein_get_state()              from public, anon, authenticated;
revoke all on function public.shein_sign(text,text,text,text) from public, anon, authenticated;
revoke all on function public.shein_signed_headers(text)     from public, anon, authenticated;
revoke all on function public.shein_exchange_token(text)     from public, anon, authenticated;
revoke all on function public.shein_refresh_token(boolean)   from public, anon, authenticated;
revoke all on function public.shein_faturamento(text)        from public, anon, authenticated;
revoke all on function public.shein_cmv(text)                from public, anon, authenticated;
grant execute on function public.shein_token_check(text)        to service_role;
grant execute on function public.shein_get_state()              to service_role;
grant execute on function public.shein_sign(text,text,text,text) to service_role;
grant execute on function public.shein_signed_headers(text)     to service_role;
grant execute on function public.shein_exchange_token(text)     to service_role;
grant execute on function public.shein_refresh_token(boolean)   to service_role;
grant execute on function public.shein_faturamento(text)        to service_role;
grant execute on function public.shein_cmv(text)                to service_role;
