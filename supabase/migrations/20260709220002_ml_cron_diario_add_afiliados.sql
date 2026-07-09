-- Adiciona o passo 'afiliados' (CVAF) ao orquestrador diário do ML, logo após o Full.
-- Mesmo padrão do Full: chama a Edge modo='afiliados' (ingestAfiliados) e loga em
-- ml_cron_log como 'diario_afiliados'. Assim a linha Afiliados do DRE se atualiza no
-- fluxo noturno (ml-diario 03:00 BRT), pescando ciclo atual + anterior por creation_date.
create or replace function public.ml_cron_diario()
returns jsonb language plpgsql security definer set search_path to 'public','extensions','vault'
as $function$
declare
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_t timestamptz; d date; i int;
  v_frete_grav int := 0; v_restam boolean := true; v_guard int := 0;
begin
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','fechar','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,valor,duracao_ms,mensagem,resposta)
  values ('diario_fechar', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'fechar'->>'upsertados')::int, (v_res->'body'->'fechar'->>'valorDia')::numeric,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  while v_restam and v_guard < 25 loop
    v_res := ml_edge_call(jsonb_build_object('modo','frete','janela',30,'limite',250));
    v_frete_grav := v_frete_grav + coalesce((v_res->'body'->'frete'->>'gravados')::int, 0);
    v_restam := coalesce((v_res->'body'->'frete'->>'restam')::boolean, false);
    v_guard := v_guard + 1;
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem)
  values ('diario_frete', v_ontem, true, v_frete_grav,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'chunks='||v_guard||' gravados='||v_frete_grav);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','ads','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,duracao_ms,mensagem,resposta)
  values ('diario_ads', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','full'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_full', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'full'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  -- NOVO: Afiliados (CVAF) — pesca ciclo atual + anterior, régua creation_date.
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','afiliados'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_afiliados', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'afiliados'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  for i in 0..6 loop
    d := v_ontem - i;
    perform ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',d::text));
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('diario_reconferir7', v_ontem, true, (extract(epoch from clock_timestamp()-v_t)*1000)::int, '7 dias');

  return jsonb_build_object('ontem', v_ontem, 'frete_gravados', v_frete_grav, 'frete_chunks', v_guard);
end $function$;

revoke all on function public.ml_cron_diario() from public, anon, authenticated;
grant execute on function public.ml_cron_diario() to service_role;
