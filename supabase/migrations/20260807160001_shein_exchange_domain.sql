-- Troca do tempToken ganha p_base_url (default produção) para suportar o fluxo de
-- DEPURAÇÃO da SHEIN (ambiente de teste usa outro domínio de interface — a página
-- "Depuração de autorização" do portal mostra host de auth de teste
-- openapi-sem-test01.dotfashion.cn e de produção openapi-sem.sheincorp.com;
-- o domínio de INTERFACE é distinto do de autorização).
-- Assinatura muda (text) -> (text, text): DROP antes para não criar overload ambíguo
-- (PostgREST não resolveria a chamada com só p_temp_token entre duas overloads).

drop function if exists public.shein_exchange_token(text);

create or replace function public.shein_exchange_token(
  p_temp_token text,
  p_base_url text default 'https://openapi.sheincorp.com'
)
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
    p_base_url || '/open-api/auth/get-by-token',
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
            'exchange_ok | openKeyId=' || v_open_key || ' | base=' || p_base_url);

    return jsonb_build_object('ok', true, 'open_key_id', v_open_key,
      'hint', 'openKeyId em shein_oauth_state, secretKey no Vault — sem expiracao/refresh');
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('shein_brigide', v_status, false,
          'exchange_falhou (' || p_base_url || '): ' || left(coalesce(v_raw, 'sem corpo'), 500));

  return jsonb_build_object('ok', false, 'error', 'exchange_failed',
    'http_status', v_status,
    'detail', coalesce(v_body->>'msg', left(v_raw, 200)));
end $$;

revoke all on function public.shein_exchange_token(text, text) from public, anon, authenticated;
grant execute on function public.shein_exchange_token(text, text) to service_role;
