-- Custódia: único ponto que decifra os secrets da Omie do vault.
-- Mesmo padrão do ml_get_state. SECURITY DEFINER (dono = postgres, que enxerga o vault).
-- Só service_role executa — a Edge Function omie-despesas chama via service role.
-- Os valores dos secrets vivem no vault (vault.create_secret 'omie_app_key' / 'omie_app_secret'),
-- NUNCA no repo.
CREATE OR REPLACE FUNCTION public.omie_get_credentials()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'app_key',    (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'omie_app_key'),
    'app_secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'omie_app_secret')
  );
$function$;

REVOKE ALL ON FUNCTION public.omie_get_credentials() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.omie_get_credentials() TO service_role;
