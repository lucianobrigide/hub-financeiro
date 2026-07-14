-- ML — ml_cron_semanal: LOG HONESTO (o ultimo sucesso=true hardcoded do cron ML).
--
-- CORRIGE DIVERGENCIA REPO<->BANCO: o commit 444fb8b capturou esta funcao ANTES deste fix
-- (pegou so o advisory lock). O fix do log veio depois e ficou vivo SO no banco — ou seja,
-- quem aplicasse as migrations do zero REINTRODUZIRIA o bug. Esta migration recaptura a
-- versao ATUAL (lock + log honesto) via pg_get_functiondef.
--
-- O BUG: o semanal_reconferir30 rodava 31 dias de ml_edge_call e logava sucesso=true SEMPRE.
-- Uma falha do semanal sumia e o alerta do ml_saude (N=2 dias) NUNCA disparava pra ele —
-- exatamente o cenario do diario_afiliados, que ficou 4 dias quebrado dizendo 'ok'.
--
-- O FIX (mesmo do diario_reconferir7): conta as falhas do loop.
--   log:     sucesso = (v_rec_falhas = 0)  + mensagem "X de 31 dias FALHARAM"
--   retorno: 'ok' = (v_rec_falhas = 0)     + 'dias_falharam'
-- O retorno tambem dizia 'ok', true fixo. Nada consome esse retorno hoje (o pg_cron
-- descarta), mas deixar o hardcode contradiz a varredura e reintroduz a mentira num campo
-- que alguem pode vir a ler.
--
-- TESTADO com falha REAL (nao sintetica): 3 chamadas, 1 com data invalida (a Edge devolveu
-- http_status 500). Resultado: sucesso=false, "1 de 3 dias FALHARAM". Antes teria logado
-- sucesso=true.
--   OBS: a 1a tentativa de teste quebrou o access_token no ml_oauth_state pra forcar erro e
--   voltou sucesso=true — TESTE INVALIDO: quebrar o token no banco NAO afeta a Edge, que
--   obtem o token pelo proprio gateway. As chamadas voltaram 200. Forcar falha na Edge exige
--   payload invalido, nao mexer no estado do token.
--
-- Com isto o cron ML fica 100% sem hardcode (diario + semanal, log e retorno).
-- Advisory lock 421982739 preservado (compartilhado com o diario = exclusao mutua).
-- Capturado via pg_get_functiondef (repo == banco).

CREATE OR REPLACE FUNCTION public.ml_cron_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1; i int; v_t timestamptz := clock_timestamp();
  v_rec_falhas int := 0; v_res jsonb;
begin
  if not pg_try_advisory_lock(421982739) then
    return jsonb_build_object('skipped', 'already_running');
  end if;
  v_rec_falhas := 0;
  for i in 0..30 loop
    v_res := ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',(v_ontem - i)::text));
    if (v_res->>'http_status') <> '200' then v_rec_falhas := v_rec_falhas + 1; end if;
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('semanal_reconferir30', v_ontem, (v_rec_falhas = 0),
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when v_rec_falhas = 0 then '31 dias'
               else v_rec_falhas||' de 31 dias FALHARAM' end);
  perform pg_advisory_unlock(421982739);
  return jsonb_build_object('ok', (v_rec_falhas = 0), 'dias', 31, 'dias_falharam', v_rec_falhas);
end $function$;
