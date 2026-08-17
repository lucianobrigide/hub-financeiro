-- Nao logar em oauth_refresh_log enquanto a MAGALU nao estiver autorizada
-- (crons rodam antes do consentimento; falhas reais de HTTP continuam logadas).

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
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'missing_credentials',
      'action', 'rodar_magalu_criar_client');
  end if;

  if v_rt is null or v_rt = '' then
    return jsonb_build_object('refreshed', false, 'valid', false, 'error', 'refresh_token_not_seeded',
      'action', 'consentimento_do_seller_necessario_via_magalu_auth_url');
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
