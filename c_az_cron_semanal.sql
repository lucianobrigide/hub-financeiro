CREATE OR REPLACE FUNCTION public.az_cron_semanal()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
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
  values ('az-semanal', v_ontem, (v_res2->>'http_status')='200', (v_res2->>'http_status')::int, v_conf_total,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          '30d re-fechados + confirmar loops='||v_guard||' com='||v_conf_total||' frete='||v_frete_total, v_res2);
  return jsonb_build_object('ok', true, 'dias', 31, 'confirmados', v_conf_total, 'frete_confirmados', v_frete_total, 'loops', v_guard);
END;
$function$
