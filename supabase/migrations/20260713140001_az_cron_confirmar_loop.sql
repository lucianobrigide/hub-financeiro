-- Confirmar em LOOP (batch de 40/chamada) no az_cron_diario e az_cron_semanal.
-- Antes: uma única chamada 'confirmar' processava TODOS os pendentes (~73) -> ~220s ->
-- estourava os 150s do curl. Agora cada chamada processa 40 (~120s, budget fresco), e o
-- cron repete até não confirmar mais nada OU zerar pendentes (guard 8). Auto-cicatrizante
-- (com o az_edge_call tolerante a falha, um batch que estoura loga e o job segue).
-- Requer a Edge az-ingest-dia com confirmAll(limit) (modo confirmar aceita body.limite).
CREATE OR REPLACE FUNCTION public.az_cron_diario()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_res2 jsonb; v_t timestamptz;
  v_conf_total int := 0; v_frete_total int := 0; v_guard int := 0; v_loop boolean := true;
BEGIN
  v_t := clock_timestamp();
  v_res := az_edge_call(jsonb_build_object('modo','fechar','dia', v_ontem::text));
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  VALUES ('az-diario', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
    COALESCE((v_res->'body'->>'pedidos')::int,0), COALESCE((v_res->'body'->>'valor')::numeric,0),
    (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  WHILE v_loop AND v_guard < 8 LOOP
    v_res2 := az_edge_call(jsonb_build_object('modo','confirmar','limite',40));
    v_conf_total  := v_conf_total  + COALESCE((v_res2->'body'->>'confirmados')::int,0);
    v_frete_total := v_frete_total + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0);
    v_loop := (COALESCE((v_res2->'body'->>'confirmados')::int,0) + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0)) > 0
              AND COALESCE((v_res2->'body'->>'pendentes')::int,0) > 0;
    v_guard := v_guard + 1;
  END LOOP;
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  VALUES ('az-confirmar', v_ontem, true, (v_res2->>'http_status')::int, v_conf_total, 0,
    (extract(epoch from clock_timestamp()-v_t)*1000)::int,
    'loops='||v_guard||' com='||v_conf_total||' frete='||v_frete_total, v_res2);

  RETURN jsonb_build_object('ontem', v_ontem,
    'pedidos', COALESCE((v_res->'body'->>'pedidos')::int,0),
    'confirmados', v_conf_total, 'frete_confirmados', v_frete_total, 'loops', v_guard);
END;
$function$;

CREATE OR REPLACE FUNCTION public.az_cron_semanal()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','vault'
AS $function$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  i int; v_t timestamptz := clock_timestamp(); v_res2 jsonb;
  v_conf_total int := 0; v_frete_total int := 0; v_guard int := 0; v_loop boolean := true;
BEGIN
  for i in 0..30 loop
    perform az_edge_call(jsonb_build_object('modo','fechar','dia',(v_ontem - i)::text));
  end loop;
  WHILE v_loop AND v_guard < 8 LOOP
    v_res2 := az_edge_call(jsonb_build_object('modo','confirmar','limite',40));
    v_conf_total  := v_conf_total  + COALESCE((v_res2->'body'->>'confirmados')::int,0);
    v_frete_total := v_frete_total + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0);
    v_loop := (COALESCE((v_res2->'body'->>'confirmados')::int,0) + COALESCE((v_res2->'body'->>'frete_confirmados')::int,0)) > 0
              AND COALESCE((v_res2->'body'->>'pendentes')::int,0) > 0;
    v_guard := v_guard + 1;
  END LOOP;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('az-semanal', v_ontem, true, (v_res2->>'http_status')::int, v_conf_total,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          '30d re-fechados + confirmar loops='||v_guard||' com='||v_conf_total||' frete='||v_frete_total, v_res2);
  return jsonb_build_object('ok', true, 'dias', 31, 'confirmados', v_conf_total, 'frete_confirmados', v_frete_total, 'loops', v_guard);
END;
$function$;

REVOKE ALL ON FUNCTION public.az_cron_diario() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.az_cron_semanal() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.az_cron_diario() TO service_role;
GRANT EXECUTE ON FUNCTION public.az_cron_semanal() TO service_role;
