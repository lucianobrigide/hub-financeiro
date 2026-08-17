-- MAGALU MVP — custódia de credencial + helper de chamada API.
-- (Versão inicial; a hipótese "API Key direta, padrão SHEIN" foi descartada na
-- migration magalu_mvp_oauth — a Magalu exige OAuth2 para dados de seller.
-- Aplicada via MCP em 17/08/2026; version 20260807* é relógio do MCP, não a data real.)
-- Segredos NUNCA aqui: magalu_api_key / magalu_api_key_secret / magalu_token_key vivem em vault.secrets.

create table public.magalu_oauth_state (
  id           integer primary key check (id = 1),
  api_key_id   text,
  tenant_id    text,
  seller_name  text,
  base_url     text not null default 'https://api.magalu.com',
  authorized_at timestamptz,
  refreshed_at  timestamptz,
  updated_at    timestamptz not null default now()
);
comment on table public.magalu_oauth_state is
  'Estado nao-sensivel da credencial MAGALU (ID Magalu API Key). A API Key NAO fica aqui — vive em vault.secrets (magalu_api_key). Sem refresh token: API Key e de longa duracao. Linha unica id=1.';
alter table public.magalu_oauth_state enable row level security;
insert into public.magalu_oauth_state (id) values (1);

create or replace function public.magalu_get_state()
returns table(api_key_id text, tenant_id text, seller_name text, base_url text, authorized_at timestamptz)
language sql security definer set search_path to 'public'
as $$ select api_key_id, tenant_id, seller_name, base_url, authorized_at from public.magalu_oauth_state where id = 1; $$;

create or replace function public.magalu_token_check(p_key text)
returns boolean
language plpgsql security definer set search_path to 'public', 'vault'
as $$
declare v_expected text;
begin
  if p_key is null or p_key = '' then return false; end if;
  select decrypted_secret into v_expected
    from vault.decrypted_secrets where name = 'magalu_token_key';
  if v_expected is null or v_expected = '' then return false; end if;
  return p_key = v_expected;
end $$;

create or replace function public.magalu_refresh_token(p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public', 'vault'
as $$
declare v_key text; v_key_id text;
begin
  select api_key_id into v_key_id from public.magalu_oauth_state where id = 1;
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'magalu_api_key';

  if v_key_id is null or v_key is null or v_key in ('', '__PLACEHOLDER__') then
    return jsonb_build_object('refreshed', false, 'valid', false,
      'error', 'magalu_nao_autorizado',
      'action', 'gravar_magalu_api_key_no_vault_e_api_key_id_no_state');
  end if;

  return jsonb_build_object('refreshed', false, 'valid', true,
    'reason', 'credencial_longa_duracao_sem_expiracao');
end $$;

-- Helper central: chamada GET autenticada (X-API-KEY + X-TENANT-ID) a partir do Postgres.
-- (Substituído em magalu_mvp_oauth por Bearer access_token.)
create or replace function public.magalu_api_get(p_path text, p_com_tenant boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions', 'vault'
as $$
declare
  v_key text; v_tenant text; v_base text;
  v_headers extensions.http_header[];
  v_resp extensions.http_response;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'magalu_api_key';
  select tenant_id, base_url into v_tenant, v_base from public.magalu_oauth_state where id = 1;

  if v_key is null or v_key in ('', '__PLACEHOLDER__') then
    return jsonb_build_object('status', 0, 'error', 'magalu_api_key_ausente_no_vault');
  end if;

  v_headers := array[extensions.http_header('X-API-KEY', v_key)];
  if p_com_tenant and v_tenant is not null then
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

revoke all on function public.magalu_token_check(text) from anon, authenticated;
revoke all on function public.magalu_refresh_token(boolean) from anon, authenticated;
revoke all on function public.magalu_api_get(text, boolean) from anon, authenticated;
