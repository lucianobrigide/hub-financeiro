-- F.C. Projetado — Saldo em conta (Omie) · 21/08/2026
--
-- A Omie devolve o saldo ATUAL de cada conta corrente por
--   POST financas/extrato/ ListarExtrato {nCodCC, dPeriodoInicial, dPeriodoFinal, cExibirApenasSaldo:'S'}
-- (nSaldoAtual = lançado até hoje · nSaldoConciliado = só o conciliado · nSaldoAtualPrevisto).
-- Descoberto/validado em 21/08/2026: Itaú Unibanco R$ 993.032,30 (conciliado R$ 1.146.182,46).
--
-- ⚠️ Nem toda "conta corrente" da Omie é CAIXA. As contas de marketplace (tipo CV:
-- Mercado Livre, Shopee, Amazon…) e a conta "Mercado Pago" são escriturais/não
-- conciliadas (Mercado Pago −R$ 1,48M, Mercado Livre −R$ 9,0M) — o saldo real
-- dessas plataformas o Hub lê das próprias plataformas (recebíveis/disponível).
-- Por isso existe `conta_caixa`: só ela entra no saldo inicial do F.C. Projetado.
-- Regra DEFAULT (aplicada no 1º insert, preservada depois — o Luciano pode ligar/
-- desligar conta a conta): tipo 'CC' + banco real 341 (Itaú), 237 (Bradesco),
-- 450 (Omie.CASH). Aplicações (Auto Mais, Trust DI) são 341 e entram.
create table if not exists public.omie_saldos_cc (
  n_cod_cc         bigint primary key,
  descricao        text,
  tipo             text,            -- CC, CX, CV, CR, PG, AD, MT…
  codigo_banco     text,
  conta_corrente   text,
  fluxo_caixa      boolean,         -- cFluxoCaixa da Omie (a conta participa do fluxo na Omie)
  conta_caixa      boolean not null default false,  -- entra no saldo inicial do Hub
  saldo_atual      numeric(14,2),
  saldo_conciliado numeric(14,2),
  saldo_previsto   numeric(14,2),
  coletado_em      timestamptz,
  raw              jsonb
);
comment on table public.omie_saldos_cc is 'Saldo por conta corrente da Omie (ListarExtrato, cExibirApenasSaldo). conta_caixa = entra no saldo inicial do F.C. Projetado (regra default: CC de banco real 341/237/450; ajustável por conta).';

-- Coleta: lista as contas (ListarResumoContasCorrentes) e pede o saldo de cada
-- uma (ListarExtrato do dia, só saldo). 28 contas ≈ 10s. Falha em uma conta não
-- derruba as outras (subtransação). Log em ml_cron_log job 'omie_saldos'.
create or replace function public.omie_fill_saldos()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
set statement_timeout to '120s'
as $$
declare
  v_key text; v_sec text; v_hoje text; v_ini timestamptz := clock_timestamp();
  v_lista jsonb; v_cc jsonb; v_resp jsonb; v_ok int := 0; v_falhas int := 0; v_err text;
begin
  if not pg_try_advisory_lock(421982821) then
    return jsonb_build_object('erro', 'ja rodando');
  end if;
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'omie_app_key';
    select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'omie_app_secret';
    v_hoje := to_char((now() at time zone 'America/Sao_Paulo')::date, 'DD/MM/YYYY');
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

    v_lista := (extensions.http_post('https://app.omie.com.br/api/v1/geral/contacorrente/',
      jsonb_build_object('call', 'ListarResumoContasCorrentes', 'app_key', v_key, 'app_secret', v_sec,
        'param', jsonb_build_array(jsonb_build_object('pagina', 1, 'registros_por_pagina', 200)))::text,
      'application/json')).content::jsonb;
    if v_lista->'conta_corrente_lista' is null then
      raise exception 'ListarResumoContasCorrentes sem lista: %', left(v_lista::text, 200);
    end if;

    for v_cc in select * from jsonb_array_elements(v_lista->'conta_corrente_lista') loop
      begin
        v_resp := (extensions.http_post('https://app.omie.com.br/api/v1/financas/extrato/',
          jsonb_build_object('call', 'ListarExtrato', 'app_key', v_key, 'app_secret', v_sec,
            'param', jsonb_build_array(jsonb_build_object('nCodCC', (v_cc->>'nCodCC')::bigint,
              'dPeriodoInicial', v_hoje, 'dPeriodoFinal', v_hoje, 'cExibirApenasSaldo', 'S')))::text,
          'application/json')).content::jsonb;
        if v_resp->>'nSaldoAtual' is null then
          raise exception 'sem nSaldoAtual: %', left(v_resp::text, 160);
        end if;
        insert into public.omie_saldos_cc as t
          (n_cod_cc, descricao, tipo, codigo_banco, conta_corrente, fluxo_caixa, conta_caixa,
           saldo_atual, saldo_conciliado, saldo_previsto, coletado_em, raw)
        values ((v_cc->>'nCodCC')::bigint, v_cc->>'descricao', v_cc->>'tipo', v_cc->>'codigo_banco',
           v_cc->>'conta_corrente', (v_resp->>'cFluxoCaixa') = 'S',
           -- regra default de caixa: conta corrente de banco real
           (v_cc->>'tipo') = 'CC' and (v_cc->>'codigo_banco') in ('341', '237', '450'),
           (v_resp->>'nSaldoAtual')::numeric, (v_resp->>'nSaldoConciliado')::numeric,
           (v_resp->>'nSaldoAtualPrevisto')::numeric, now(), v_resp - 'listaMovimentos')
        on conflict (n_cod_cc) do update set
           descricao = excluded.descricao, tipo = excluded.tipo, codigo_banco = excluded.codigo_banco,
           conta_corrente = excluded.conta_corrente, fluxo_caixa = excluded.fluxo_caixa,
           -- conta_caixa é decisão humana: NUNCA sobrescrita pela coleta
           saldo_atual = excluded.saldo_atual, saldo_conciliado = excluded.saldo_conciliado,
           saldo_previsto = excluded.saldo_previsto, coletado_em = excluded.coletado_em, raw = excluded.raw;
        v_ok := v_ok + 1;
      exception when others then
        v_falhas := v_falhas + 1;
        v_err := coalesce(v_err || ' | ', '') || (v_cc->>'descricao') || ': ' || left(sqlerrm, 120);
      end;
      perform pg_sleep(0.15);
    end loop;

    insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, pedidos, valor, duracao_ms, mensagem)
    values (now(), 'omie_saldos', (now() at time zone 'America/Sao_Paulo')::date, v_falhas = 0, v_ok,
            (select sum(saldo_atual) from public.omie_saldos_cc where conta_caixa),
            (extract(epoch from clock_timestamp() - v_ini) * 1000)::int,
            format('%s contas atualizadas, %s falhas%s', v_ok, v_falhas, coalesce(' — ' || v_err, '')));
  exception when others then
    insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
    values (now(), 'omie_saldos', (now() at time zone 'America/Sao_Paulo')::date, false, left(sqlerrm, 300));
    perform pg_advisory_unlock(421982821);
    raise;
  end;
  perform pg_advisory_unlock(421982821);
  return jsonb_build_object('contas_ok', v_ok, 'falhas', v_falhas, 'erros', v_err,
    'saldo_caixa', (select sum(saldo_atual) from public.omie_saldos_cc where conta_caixa));
end $$;

revoke all on function public.omie_fill_saldos() from public, anon, authenticated;

-- Leitura para o F.C. Projetado: total das contas marcadas como caixa + a lista
-- completa (pra quem lê saber o que entrou e o que ficou de fora).
create or replace function public.fc_saldo_caixa()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
select jsonb_build_object(
  'total', coalesce((select sum(saldo_atual) from omie_saldos_cc where conta_caixa), 0)::numeric(14,2),
  'total_conciliado', coalesce((select sum(saldo_conciliado) from omie_saldos_cc where conta_caixa), 0)::numeric(14,2),
  'contas_caixa', (select count(*) from omie_saldos_cc where conta_caixa),
  'coletado_em', (select max(coletado_em) from omie_saldos_cc where conta_caixa),
  'contas', coalesce((select jsonb_agg(jsonb_build_object(
      'codigo', n_cod_cc, 'descricao', descricao, 'tipo', tipo, 'banco', codigo_banco,
      'conta_caixa', conta_caixa, 'saldo_atual', saldo_atual, 'saldo_conciliado', saldo_conciliado,
      'coletado_em', coletado_em)
      order by conta_caixa desc, abs(coalesce(saldo_atual, 0)) desc)
    from omie_saldos_cc), '[]'::jsonb)
);
$$;
revoke all on function public.fc_saldo_caixa() from public, anon;
grant execute on function public.fc_saldo_caixa() to service_role, authenticated;

-- Cron: 2 fotos por dia (08:30 e 16:30 BRT = 11:30/19:30 UTC), depois do omie-diario (05:00 BRT).
select cron.schedule('omie-saldos', '30 11,19 * * *', $$select public.omie_fill_saldos();$$);

-- Catálogo da página /crons (mesma técnica idempotente das outras migrations).
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('omie-saldos' in v_def) > 0 then
    raise notice 'catálogo já tem omie-saldos';
    return;
  end if;

  v_row := $r$('omie-saldos','Omie','diario','Todo dia às 08:30 e 16:30 BRT',
     'Pergunta à Omie o saldo atual de cada conta corrente (Itaú, Bradesco, aplicações…). É o saldo inicial do Saldo Projetado no F.C. Projetado — só as contas marcadas como caixa entram.',
     'honesto', 16, null),
    $r$;

  v_new := replace(
    v_def,
    '(''ml-semanal'',''Mercado Livre'',''semanal''',
    v_row || '(''ml-semanal'',''Mercado Livre'',''semanal'''
  );

  if v_new = v_def then
    raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado';
  end if;

  execute v_new;
end
$do$;
