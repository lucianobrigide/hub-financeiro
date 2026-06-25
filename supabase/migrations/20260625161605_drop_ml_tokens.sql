-- Remove a implementação antiga (tokens em coluna), substituída pela custódia
-- via Vault + ml_oauth_state.
drop table if exists public.ml_tokens;            -- o trigger ml_tokens_updated_at cai junto
drop function if exists public.update_updated_at();
