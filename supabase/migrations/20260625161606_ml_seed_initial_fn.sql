-- RPC chamado UMA vez pela rota de callback OAuth (authorization_code) para
-- semear o Vault com as credenciais reais e gravar o access_token inicial em
-- ml_oauth_state. SECURITY DEFINER (escreve no Vault); só service_role executa.
create or replace function public.ml_seed_initial(
  p_client_id     text,
  p_client_secret text,
  p_refresh_token text,
  p_access_token  text,
  p_token_type    text,
  p_scope         text,
  p_expires_in    bigint,
  p_user_id       text
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'vault'
as $function$
begin
  if p_client_id is null or p_client_secret is null or p_refresh_token is null
     or p_refresh_token = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_required_values');
  end if;

  -- Custódia: refresh_token e credenciais vão SÓ para o Vault.
  perform vault.update_secret((select id from vault.secrets where name='ml_client_id'),     p_client_id);
  perform vault.update_secret((select id from vault.secrets where name='ml_client_secret'), p_client_secret);
  perform vault.update_secret((select id from vault.secrets where name='ml_refresh_token'), p_refresh_token);

  -- Estado não-sensível: access_token em cache + metadados.
  update public.ml_oauth_state
     set access_token = p_access_token,
         token_type   = p_token_type,
         scope        = p_scope,
         expires_at   = now() + (coalesce(p_expires_in, 0) || ' seconds')::interval,
         refreshed_at = now(),
         user_id      = coalesce(p_user_id, user_id),
         updated_at   = now()
   where id = 1;

  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.ml_seed_initial(text,text,text,text,text,text,bigint,text)
  from public, anon, authenticated;
grant execute on function public.ml_seed_initial(text,text,text,text,text,text,bigint,text)
  to service_role;
