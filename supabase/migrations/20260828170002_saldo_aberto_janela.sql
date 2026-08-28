-- Fix da 20260828170001 (mesma sessão): a janela venc 01/01/2026→31/12/2031
-- devolve ~4.500 títulos (23 páginas, liquidados inclusos) — o cap de 20
-- páginas truncava ANTES de alcançar os títulos-alvo (2282/3954 ficaram sem
-- saldo). Janela corrigida para venc ≥ 01/08/2026 (o CORTE fixo do F.C.):
-- 610 títulos ≈ 4 páginas. Limitação assumida: título com venc < 01/08
-- reprogramado por previsão para frente fica sem saldo aberto sincronizado
-- (raro; o corte do F.C. já exclui esses do exigível).

create or replace function public.omie_fill_titulos_aberto()
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $function$
declare
  v_cred jsonb := public.omie_get_credentials();
  v_pag int := 1; v_tot_pag int := 1; v_resp jsonb; v_n int := 0; v_err text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');
  create temp table _aberto (cod bigint primary key, aberto numeric, liquidado text) on commit drop;
  while v_pag <= v_tot_pag and v_pag <= 20 loop
    v_resp := (extensions.http((
      'POST', 'https://app.omie.com.br/api/v1/financas/pesquisartitulos/',
      ARRAY[extensions.http_header('Content-Type','application/json')], 'application/json',
      jsonb_build_object(
        'call','PesquisarLancamentos',
        'app_key', v_cred->>'app_key', 'app_secret', v_cred->>'app_secret',
        'param', jsonb_build_array(jsonb_build_object(
          'nPagina', v_pag, 'nRegPorPagina', 200, 'cNatureza', 'P',
          'dDtVencDe', '01/08/2026', 'dDtVencAte', '31/12/2031')))::text
    )::extensions.http_request)).content::jsonb;
    if v_resp->>'nTotPaginas' is null and v_pag = 1 then
      raise exception 'PesquisarLancamentos sem nTotPaginas: %', left(v_resp::text, 200);
    end if;
    v_tot_pag := coalesce((v_resp->>'nTotPaginas')::int, v_pag);
    insert into _aberto
    select (t->'cabecTitulo'->>'nCodTitulo')::bigint,
           (t->'resumo'->>'nValAberto')::numeric,
           t->'resumo'->>'cLiquidado'
    from jsonb_array_elements(coalesce(v_resp->'titulosEncontrados', '[]'::jsonb)) t
    on conflict (cod) do nothing;
    v_pag := v_pag + 1;
  end loop;
  if v_tot_pag > 20 then
    raise exception 'PesquisarLancamentos com % páginas (> cap 20) — janela grande demais, sincronização abortada para não gravar parcial', v_tot_pag;
  end if;
  select count(*) into v_n from _aberto;
  update public.omie_despesas set valor_aberto = null, liquidado = null where valor_aberto is not null;
  update public.omie_despesas d
     set valor_aberto = a.aberto, liquidado = a.liquidado, aberto_em = now()
  from _aberto a where a.cod = d.codigo_lancamento_omie;
  drop table _aberto;
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'omie_aberto', (now() at time zone 'America/Sao_Paulo')::date, true,
          format('saldo aberto sincronizado: %s títulos (venc 01/08/2026→31/12/2031)', v_n));
  return jsonb_build_object('ok', true, 'titulos', v_n);
exception when others then
  v_err := sqlerrm;
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'omie_aberto', (now() at time zone 'America/Sao_Paulo')::date, false, 'ERRO: ' || left(v_err, 250));
  return jsonb_build_object('ok', false, 'erro', v_err);
end $function$;
