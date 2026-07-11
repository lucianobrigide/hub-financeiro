-- Fix: ml_edge_call NÃO derruba mais o orquestrador quando a chamada à Edge falha
-- (timeout 150s / erro de rede). Captura a exceção e retorna erro logável. Como o
-- ml_cron_diario/ml_cron_semanal só logam o resultado e seguem (não abortam por erro),
-- isso torna CADA passo tolerante a falha. O desenho já é auto-cicatrizante: o passo que
-- falhou é repescado no próximo run.
--
-- Causa raiz (falha de 2026-07-11 03:00): um passo — afiliados ou DIFAL — estourou os
-- 150s sob rate-limit 429 do billing do ML, a exceção da extensions.http() propagava e
-- abortava o ml_cron_diario inteiro (perdendo ads/full/reconferência do dia). Agora o
-- passo que falha vira 'edge_call_falhou' no ml_cron_log e o orquestrador continua.
create or replace function public.ml_edge_call(p_body jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','extensions','vault'
as $function$
declare
  v_url text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/ml-ingest-dia';
  v_key text; v_status int; v_raw text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'ml_token_key';
  if v_key is null or v_key = '' then
    return jsonb_build_object('http_status', 0, 'body', jsonb_build_object('error','missing_key'));
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '150000');
  begin
    select r.status, r.content into v_status, v_raw
    from extensions.http((
      'POST', v_url, array[ extensions.http_header('x-api-key', v_key) ],
      'application/json', p_body::text
    )::extensions.http_request) as r;
  exception when others then
    -- timeout / erro de rede: NÃO propaga (senão aborta o orquestrador inteiro).
    -- Vira erro logável; o passo é repescado no próximo run (auto-cicatrizante).
    return jsonb_build_object('http_status', 0,
      'body', jsonb_build_object('error','edge_call_falhou','detalhe', left(SQLERRM, 200)));
  end;
  return jsonb_build_object('http_status', v_status,
    'body', case when left(coalesce(v_raw, ''), 1) = '{' then v_raw::jsonb else to_jsonb(coalesce(v_raw,'')) end);
end $function$;

revoke all on function public.ml_edge_call(jsonb) from public, anon, authenticated;
grant execute on function public.ml_edge_call(jsonb) to service_role;
