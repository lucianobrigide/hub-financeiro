-- ML — advisory lock 421982739 estendido ao ml_cron_semanal.
--
-- COMPLETA a robustez do cron ML (o commit 1ba6e74 pos o lock so no diario). O semanal
-- ficava de fora, o que era MEIA-CORRECAO da mesma classe de bug: diario (03:00) e semanal
-- (domingo 05:00) mexem nas MESMAS tabelas e batem na MESMA API do ML, que rate-limita
-- sob carga (429). Sem lock compartilhado, um run longo do diario podia encavalar com o
-- semanal.
--
-- MESMO numero do diario (421982739), de proposito: e assim que o lock vira exclusao mutua
-- entre os dois. E o padrao ja usado em shopee_cron_diario/semanal (738) e
-- tt_cron_diario/semanal (737).
--
-- Lock de SESSAO (nao xact): o pg_cron roda cada job num backend proprio, entao o lock cai
-- sozinho ao fim do job mesmo se estourar excecao — sem precisar de unlock no handler.
--
-- TESTADO com 2 CONEXOES REAIS (jobs pg_cron distintos), nos DOIS sentidos: com o lock
-- tomado por outra sessao, tanto ml_cron_semanal() quanto ml_cron_diario() devolveram
-- literalmente {"skipped": "already_running"}.
--   ARMADILHA: pg_try_advisory_lock e RE-ENTRANTE na mesma sessao. Testar de uma conexao
--   so da FALSO POSITIVO — o lock e readquirido e o cron roda assim mesmo. Tem que ser
--   2 sessoes distintas.
--
-- Capturado via pg_get_functiondef (repo == banco).

CREATE OR REPLACE FUNCTION public.ml_cron_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1; i int; v_t timestamptz := clock_timestamp();
begin
  if not pg_try_advisory_lock(421982739) then
    return jsonb_build_object('skipped', 'already_running');
  end if;
  for i in 0..30 loop
    perform ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',(v_ontem - i)::text));
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('semanal_reconferir30', v_ontem, true, (extract(epoch from clock_timestamp()-v_t)*1000)::int, '30 dias');
  perform pg_advisory_unlock(421982739);
  return jsonb_build_object('ok', true, 'dias', 31);
end $function$;
