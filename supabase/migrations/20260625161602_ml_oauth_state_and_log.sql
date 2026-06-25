-- Passos 3 e 4 da receita: estado não-sensível + log de auditoria + validação da chave.

-- Passo 3: estado não-sensível (singleton id=1). refresh_token NÃO fica aqui.
create table if not exists public.ml_oauth_state (
  id           integer primary key default 1,
  account      text        not null default 'brigide',
  access_token text,
  token_type   text,
  scope        text,
  expires_at   timestamptz,
  refreshed_at timestamptz,
  user_id      text,
  updated_at   timestamptz not null default now(),
  constraint ml_oauth_state_singleton check (id = 1)
);
comment on table public.ml_oauth_state is
  'Estado nao-sensivel do token OAuth do ML. O refresh_token NAO fica aqui — vive em vault.secrets (ml_refresh_token). Linha unica id=1.';
alter table public.ml_oauth_state enable row level security;  -- RLS sem policies: só service_role / SECURITY DEFINER
insert into public.ml_oauth_state (id, account) values (1, 'brigide')
on conflict (id) do nothing;

-- Passo 4a: auditoria de refresh (nunca recebe tokens/segredos)
create table if not exists public.oauth_refresh_log (
  id              bigint generated always as identity primary key,
  conta           text        not null,
  http_status     int,
  success         boolean     not null default false,
  message         text,
  expires_at_novo bigint,
  created_at      timestamptz not null default now()
);
alter table public.oauth_refresh_log enable row level security;
create index if not exists oauth_refresh_log_conta_idx
  on public.oauth_refresh_log (conta, id desc);

-- Passo 4b: valida o x-api-key contra o Vault (fail-closed)
create or replace function public.ml_token_check(p_key text)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'vault'
as $function$
declare
  v_expected text;
begin
  if p_key is null or p_key = '' then
    return false;
  end if;
  select decrypted_secret into v_expected
    from vault.decrypted_secrets where name = 'ml_token_key';
  if v_expected is null or v_expected = '' or v_expected = '__SET_ME__' then
    return false;  -- fail-closed
  end if;
  return p_key = v_expected;
end;
$function$;
revoke all on function public.ml_token_check(text) from public, anon, authenticated;
grant execute on function public.ml_token_check(text) to service_role;
