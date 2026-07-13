-- Fix: az_edge_call tolerante a falha (idêntico ao ml_edge_call de 20260711100005).
-- Um passo que estoura os 150s / erro de rede NÃO derruba mais o az_cron_diario /
-- az_cron_semanal — captura a exceção e retorna erro logável; o passo é repescado no
-- próximo run (auto-cicatrizante).
--
-- Causa raiz: az-diario falhou em 2026-07-13 03:15 com "Operation timed out after
-- 150001 ms" — o passo 'confirmar' (Finances API) cresceu de ~116s (09-11/07) p/ ~173s
-- e estourou o timeout do curl, abortando o orquestrador inteiro. Shopee/TikTok não têm
-- esse padrão (chamam a API direto do PG, não via Edge).
CREATE OR REPLACE FUNCTION public.az_edge_call(p_body jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_url text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/az-ingest-dia';
  v_key text; v_status int; v_raw text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'az_token_key';
  IF v_key IS NULL OR v_key = '' THEN
    RETURN jsonb_build_object('http_status', 0, 'body', jsonb_build_object('error','missing_key'));
  END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '150000');
  BEGIN
    SELECT r.status, r.content INTO v_status, v_raw
    FROM extensions.http((
      'POST', v_url, array[ extensions.http_header('x-api-key', v_key) ],
      'application/json', p_body::text
    )::extensions.http_request) AS r;
  EXCEPTION WHEN OTHERS THEN
    -- timeout / erro de rede: NÃO propaga (senão aborta o orquestrador). Vira erro logável.
    RETURN jsonb_build_object('http_status', 0,
      'body', jsonb_build_object('error','edge_call_falhou','detalhe', left(SQLERRM, 200)));
  END;
  RETURN jsonb_build_object('http_status', v_status,
    'body', CASE WHEN left(coalesce(v_raw,''),1) = '{' THEN v_raw::jsonb ELSE to_jsonb(coalesce(v_raw,'')) END);
END;
$function$;

REVOKE ALL ON FUNCTION public.az_edge_call(jsonb) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.az_edge_call(jsonb) TO service_role;
