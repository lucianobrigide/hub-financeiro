-- Passo 1 da receita "Token ML no Supabase": extensões necessárias.
create extension if not exists supabase_vault;     -- Vault (vault.secrets, vault.decrypted_secrets)
create extension if not exists pg_cron;            -- agendador
create extension if not exists http with schema extensions;  -- chamadas HTTP de dentro do Postgres
