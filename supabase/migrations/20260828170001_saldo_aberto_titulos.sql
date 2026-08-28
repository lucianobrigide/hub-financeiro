-- ═══════════════════════════════════════════════════════════════════════════
-- Saldo ABERTO por título: baixa parcial por crédito/desconto vira saldo real
-- (28/08/2026; casos do Luciano: NF 2282 Firenze — baixa parcial por NF de
-- devolução nº 18, saldo R$ 29.000 p/ 10/09 — e NF 3954 Arnix — desconto
-- financeiro, saldo R$ 17.040 p/ 10/09; nos dois NÃO houve desembolso)
--
-- Causa raiz: o ListarContasPagar devolve status_titulo = "PAGO" para título
-- com baixa PARCIAL por crédito (e o ConsultarContaPagar devolve valor_pag=0,
-- inútil) — o Hub tirava o título inteiro da projeção e o saldo real sumia.
-- A verdade está no `financas/pesquisartitulos/` (PesquisarLancamentos):
-- resumo.nValAberto / nValPago / nDesconto / cLiquidado. Validado ao vivo:
-- 2282 → valor 58.181, desconto 29.181, ABERTO 29.000, cLiquidado=N;
-- 3954 → valor 91.590, desconto 74.550, ABERTO 17.040, cLiquidado=N.
-- (A pesquisa só devolve títulos NÃO liquidados: 610 na janela testada.)
--
-- Regra geral (não caso a caso): valor projetado do título = nValAberto quando
-- conhecido (qualquer baixa parcial, desconto ou crédito, hoje e no futuro);
-- título "PAGO" com aberto > 0 CONTINUA na projeção pelo saldo; aberto = 0 ou
-- não retornado (liquidado de fato) sai. Coleta 2×/dia junto das passadas do
-- AP (crons omie-aberto-manha 05:10 / omie-aberto-tarde 16:30 BRT).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.omie_despesas
  add column if not exists valor_aberto numeric(14,2),
  add column if not exists liquidado text,
  add column if not exists aberto_em timestamptz;

comment on column public.omie_despesas.valor_aberto is
'resumo.nValAberto do PesquisarLancamentos (saldo real a pagar; cobre baixa parcial por crédito/desconto que o ListarContasPagar esconde atrás de status PAGO). NULL = título não retornado na última sincronização (liquidado de fato ou fora da janela).';

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
          'dDtVencDe', '01/01/2026', 'dDtVencAte', '31/12/2031')))::text
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
  select count(*) into v_n from _aberto;
  -- reset + regrava: título que sumiu da pesquisa (liquidado de fato) volta a NULL
  update public.omie_despesas set valor_aberto = null, liquidado = null where valor_aberto is not null;
  update public.omie_despesas d
     set valor_aberto = a.aberto, liquidado = a.liquidado, aberto_em = now()
  from _aberto a where a.cod = d.codigo_lancamento_omie;
  drop table _aberto;
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'omie_aberto', (now() at time zone 'America/Sao_Paulo')::date, true,
          format('saldo aberto sincronizado: %s títulos (venc 01/01/2026→31/12/2031)', v_n));
  return jsonb_build_object('ok', true, 'titulos', v_n);
exception when others then
  v_err := sqlerrm;
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'omie_aberto', (now() at time zone 'America/Sao_Paulo')::date, false, 'ERRO: ' || left(v_err, 250));
  return jsonb_build_object('ok', false, 'erro', v_err);
end $function$;

comment on function public.omie_fill_titulos_aberto() is
'Sincroniza o saldo em aberto por título (PesquisarLancamentos → omie_despesas.valor_aberto/liquidado). Roda 2×/dia após as passadas do AP (crons omie-aberto-manha/tarde). Reset-e-regrava: título não retornado = liquidado → valor_aberto NULL.';

-- crons: logo após omie-diario (08:00 UTC) e omie-ap-tarde (19:20 UTC)
select cron.schedule('omie-aberto-manha', '10 8 * * *',  $$select public.omie_fill_titulos_aberto();$$);
select cron.schedule('omie-aberto-tarde', '30 19 * * *', $$select public.omie_fill_titulos_aberto();$$);
