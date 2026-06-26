-- Leitura do estado via RPC SECURITY DEFINER. A Edge Function ml-token usa este
-- RPC em vez de um SELECT direto na tabela: não depende de o service_role furar
-- a RLS no PostgREST (que, dependendo do sistema de API keys do projeto, não
-- bypassa o SELECT direto). Mesma abordagem do ml_token_check.
create or replace function public.ml_get_state()
returns table(access_token text, expires_at timestamptz, user_id text)
language sql
security definer
set search_path to 'public'
as $function$
  select access_token, expires_at, user_id
  from public.ml_oauth_state
  where id = 1;
$function$;

revoke all on function public.ml_get_state() from public, anon, authenticated;
grant execute on function public.ml_get_state() to service_role;
