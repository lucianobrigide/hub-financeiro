-- Passo 5 da receita: refresh atômico sob advisory lock, com HTTP dentro da transação.
create or replace function public.ml_refresh_token(p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_margin    interval := case when p_force then interval '10 minutes' else interval '30 minutes' end;
  v_cid       text;  v_csec   text;  v_rt     text;  v_rt_id   uuid;
  v_exp       timestamptz;  v_uid  text;
  v_status    int;   v_raw    text;  v_body   jsonb;  v_expin   bigint;
  v_new_rt    text;  v_access text;  v_new_exp timestamptz;
  v_me_status int;   v_me_raw text;
begin
  -- guard de concorrência: serializa qualquer refresh da conta.
  -- lock de transação (xact) => abrange a chamada HTTP inteira, liberado no commit/rollback.
  perform pg_advisory_xact_lock(421982731);   -- chave única por conta/integração

  select expires_at, user_id into v_exp, v_uid
  from public.ml_oauth_state where id = 1;

  -- double-checked: já temos token bom além da folga -> não rotaciona (cache hit)
  if v_exp is not null and v_exp > now() + v_margin then
    return jsonb_build_object('refreshed', false, 'valid', true,
                              'expires_at', v_exp, 'reason', 'cache_hit');
  end if;

  -- credenciais + refresh_token vêm SOMENTE do Vault
  select decrypted_secret into v_cid  from vault.decrypted_secrets where name = 'ml_client_id';
  select decrypted_secret into v_csec from vault.decrypted_secrets where name = 'ml_client_secret';
  select decrypted_secret into v_rt   from vault.decrypted_secrets where name = 'ml_refresh_token';
  select id              into v_rt_id from vault.secrets         where name = 'ml_refresh_token';

  if v_cid is null or v_csec is null then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('ml_brigide', null, false, 'ml_client_id/ml_client_secret ausentes no Vault');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials');
  end if;
  if v_rt is null or v_rt = '' or v_rt = '__SET_ME__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('ml_brigide', null, false, 'ml_refresh_token nao semeado no Vault (cadeia nao inicializada)');
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- POST de refresh (x-www-form-urlencoded). client_id/secret no body (padrão ML).
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST',
    'https://api.mercadolibre.com/oauth/token',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/x-www-form-urlencoded',
    'grant_type=refresh_token'
      || '&client_id='     || v_cid
      || '&client_secret=' || v_csec
      || '&refresh_token=' || v_rt
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else null end;

  if v_status = 200 and v_body ? 'access_token' then
    v_access  := v_body->>'access_token';
    v_new_rt  := v_body->>'refresh_token';
    v_expin   := coalesce((v_body->>'expires_in')::bigint, 0);
    v_new_exp := now() + (v_expin || ' seconds')::interval;

    -- 1) PRIMEIRO: persistir o refresh_token NOVO no Vault (mesma transação = atômico)
    if v_new_rt is not null and v_new_rt <> '' then
      perform vault.update_secret(v_rt_id, v_new_rt);
    end if;

    -- 2) capturar user_id uma única vez (quando ainda desconhecido)
    if v_uid is null then
      select r.status, r.content into v_me_status, v_me_raw
      from extensions.http((
        'GET', 'https://api.mercadolibre.com/users/me',
        array[ extensions.http_header('Authorization', 'Bearer ' || v_access) ],
        null, null
      )::extensions.http_request) as r;
      if v_me_status = 200 and left(coalesce(v_me_raw, ''), 1) = '{' then
        v_uid := (v_me_raw::jsonb)->>'id';
      end if;
    end if;

    -- 3) atualizar estado não-sensível
    update public.ml_oauth_state
       set access_token = v_access,
           token_type   = v_body->>'token_type',
           scope        = v_body->>'scope',
           expires_at   = v_new_exp,
           refreshed_at = now(),
           user_id      = coalesce(v_uid, user_id),
           updated_at   = now()
     where id = 1;

    -- 4) log (sem valores sensíveis)
    insert into public.oauth_refresh_log(conta, http_status, success, message, expires_at_novo)
    values ('ml_brigide', v_status, true, 'ok', extract(epoch from v_new_exp)::bigint);

    return jsonb_build_object('refreshed', true, 'valid', true,
                              'expires_at', v_new_exp, 'user_id', v_uid);
  end if;

  -- invalid_grant => cadeia quebrada. NÃO insistir; logar p/ reautorização manual.
  if v_body ? 'error' and v_body->>'error' = 'invalid_grant' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('ml_brigide', v_status, false,
            'INVALID_GRANT: cadeia de refresh quebrada — requer reautorizacao manual do app ML');
    return jsonb_build_object('refreshed', false, 'valid', false,
                              'error', 'invalid_grant', 'action', 'reautorizacao_manual_necessaria');
  end if;

  -- outra falha qualquer
  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('ml_brigide', v_status, false, left(coalesce(v_raw, 'sem corpo'), 500));
  return jsonb_build_object('refreshed', false, 'valid', false,
                            'error', 'refresh_failed', 'http_status', v_status);
end;
$function$;

revoke all on function public.ml_refresh_token(boolean) from public, anon, authenticated;
grant execute on function public.ml_refresh_token(boolean) to service_role;
