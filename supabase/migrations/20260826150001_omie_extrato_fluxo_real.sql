-- F.C. Projetado: FLUXO REAL dos dias passados via EXTRATO da Omie
-- (pedido do Luciano 26/08/2026: "no saldo projetado o dia 25/08 mostra
--  −R$ 65.941,19, quando na verdade pagamos muito mais nesse dia. Estamos
--  falando de fluxo de caixa. Precisa bater").
--
-- O problema: o histórico da curva fechava o dia pela DIFERENÇA entre duas
-- fotos de saldo (fc_snapshot, 08:45) — um único número LÍQUIDO (entradas −
-- saídas), exibido na coluna de saídas. No dia 25/08 saíram ~R$ 651k e
-- entraram ~R$ 585k; o líquido −R$ 65,9k lia como "pagamos só 65,9k". Errado
-- para fluxo de caixa.
--
-- A fonte certa existe: `financas/extrato/ListarExtrato` POR CONTA e POR DIA
-- devolve `listaMovimentos` (cada crédito e débito real, com categoria,
-- contraparte e id) e `nSaldoAtual` = SALDO NO FIM DO PERÍODO consultado
-- (validado 26/08: janela 25/08 devolveu Itaú R$ 418.731,76; menos os
-- R$ 180.809,52 pagos na manhã de 26/08 = R$ 237.922,24, o saldo atual da
-- tela — bate centavo a centavo). Com isso o dia fecha EXATO por construção:
--   fechamento(D) = fechamento(D−1) + entradas_reais(D) − saídas_reais(D).
--
-- Régua de agregação (fc_historico): soma sobre as contas de caixa
-- (omie_saldos_cc.conta_caixa). Transferência entre DUAS contas de caixa
-- (ex.: Itaú → Bradesco Invest) é remanejamento interno: sai do bruto de
-- entradas/saídas (não é fluxo externo e se anula no saldo). Transferência
-- vinda de conta NÃO-caixa (Mercado Pago, Shopee, TikTok…) é ENTRADA REAL —
-- é o dinheiro dos marketplaces chegando ao caixa. Identificação: categoria
-- 0.01.% + nomes em "Transf. A &gt;&gt; B" comparados às contas de caixa.
--
-- fc_snapshot continua existindo (backtest da projeção); a curva usa o
-- extrato quando o dia tem TODAS as contas de caixa coletadas, senão cai na
-- foto (fonte explícita no contrato).
--
-- ⚠️ O extrato mistura 3 situações (medido 26/08): `Conciliado` e
-- `Não conciliado` = movimento REAL lançado (compõem o nSaldoAtual);
-- `Previsto` = previsão de conta a pagar/NF/pedido de compra (compõe só o
-- nSaldoPrev — NÃO é dinheiro que se moveu). Sem filtrar 'Previsto' a
-- identidade quebrava em 3 dias (ex.: 10/08 com −R$ 197,9k de previsão de
-- pedido de compra contada como saída). Filtrado na coleta E na leitura.

create table if not exists public.omie_extrato_dia (
  n_cod_cc    bigint not null,
  data        date not null,
  creditos    numeric(14,2) not null,  -- Σ movimentos positivos do dia (bruto)
  debitos     numeric(14,2) not null,  -- Σ |movimentos negativos| do dia (bruto)
  saldo_fim   numeric(14,2),           -- nSaldoAtual da janela [dia, dia] = saldo no fim do dia
  movimentos  jsonb not null,          -- listaMovimentos sem as linhas-fantasma de saldo (valor 0)
  coletado_em timestamptz not null default now(),
  primary key (n_cod_cc, data)
);
comment on table public.omie_extrato_dia is
'Extrato diário por conta de caixa da Omie (ListarExtrato, janela de 1 dia): movimentos reais + saldo de fim de dia. Alimenta o fluxo real dos dias passados no F.C. Projetado. Coleta: omie_fill_extrato(dias), junto do omie-saldos (08:30/16:30 BRT).';

create or replace function public.omie_fill_extrato(p_dias int default 5)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
set statement_timeout to '390s'
as $function$
declare
  v_key text; v_sec text; v_ini timestamptz := clock_timestamp();
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_cc record; v_dia date; v_resp jsonb; v_movs jsonb;
  v_ok int := 0; v_falhas int := 0; v_err text;
begin
  if not pg_try_advisory_lock(421982831) then
    return jsonb_build_object('erro', 'ja rodando');
  end if;
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets where name = 'omie_app_key';
    select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'omie_app_secret';
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

    for v_cc in select n_cod_cc, descricao from public.omie_saldos_cc where conta_caixa loop
      for v_dia in select generate_series(v_hoje - p_dias, v_hoje, interval '1 day')::date loop
        begin
          v_resp := (extensions.http_post('https://app.omie.com.br/api/v1/financas/extrato/',
            jsonb_build_object('call', 'ListarExtrato', 'app_key', v_key, 'app_secret', v_sec,
              'param', jsonb_build_array(jsonb_build_object('nCodCC', v_cc.n_cod_cc,
                'dPeriodoInicial', to_char(v_dia, 'DD/MM/YYYY'),
                'dPeriodoFinal',   to_char(v_dia, 'DD/MM/YYYY'))))::text,
            'application/json')).content::jsonb;
          if v_resp->>'nSaldoAtual' is null then
            raise exception 'sem nSaldoAtual: %', left(v_resp::text, 160);
          end if;
          -- linhas-fantasma (SALDO ANTERIOR / SALDO) têm nValorDocumento = 0;
          -- 'Previsto' é previsão (conta a pagar/NF/pedido futuro), não movimento real
          select coalesce(jsonb_agg(m), '[]'::jsonb) into v_movs
          from jsonb_array_elements(coalesce(v_resp->'listaMovimentos', '[]'::jsonb)) m
          where (m->>'nValorDocumento')::numeric <> 0
            and coalesce(m->>'cSituacao', '') <> 'Previsto';

          insert into public.omie_extrato_dia as t (n_cod_cc, data, creditos, debitos, saldo_fim, movimentos, coletado_em)
          select v_cc.n_cod_cc, v_dia,
                 coalesce((select sum((m->>'nValorDocumento')::numeric) from jsonb_array_elements(v_movs) m
                           where (m->>'nValorDocumento')::numeric > 0), 0),
                 coalesce((select -sum((m->>'nValorDocumento')::numeric) from jsonb_array_elements(v_movs) m
                           where (m->>'nValorDocumento')::numeric < 0), 0),
                 (v_resp->>'nSaldoAtual')::numeric, v_movs, now()
          on conflict (n_cod_cc, data) do update set
            creditos = excluded.creditos, debitos = excluded.debitos,
            saldo_fim = excluded.saldo_fim, movimentos = excluded.movimentos,
            coletado_em = excluded.coletado_em;
          v_ok := v_ok + 1;
        exception when others then
          v_falhas := v_falhas + 1;
          v_err := coalesce(v_err || ' | ', '') || v_cc.descricao || ' ' || to_char(v_dia, 'DD/MM') || ': ' || left(sqlerrm, 100);
        end;
        perform pg_sleep(0.12);
      end loop;
    end loop;

    insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, pedidos, duracao_ms, mensagem)
    values (now(), 'omie_extrato', v_hoje, v_falhas = 0, v_ok,
            (extract(epoch from clock_timestamp() - v_ini) * 1000)::int,
            format('%s conta×dia atualizados (janela %s dias), %s falhas%s',
                   v_ok, p_dias, v_falhas, coalesce(' — ' || v_err, '')));
  exception when others then
    insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
    values (now(), 'omie_extrato', v_hoje, false, left(sqlerrm, 300));
    perform pg_advisory_unlock(421982831);
    raise;
  end;
  perform pg_advisory_unlock(421982831);
  return jsonb_build_object('conta_dias_ok', v_ok, 'falhas', v_falhas, 'erros', v_err);
end $function$;

revoke all on function public.omie_fill_extrato(int) from public, anon, authenticated;
comment on function public.omie_fill_extrato(int) is
'Coleta o extrato diário (ListarExtrato, 1 chamada por conta de caixa × dia da janela [hoje-p_dias, hoje]) em omie_extrato_dia: movimentos reais + saldo de fim de dia. Roda junto do omie-saldos (08:30/16:30 BRT). Log em ml_cron_log job omie_extrato.';

-- fc_historico v3: dias passados fecham pelo EXTRATO (fluxo real) quando o dia
-- tem todas as contas de caixa coletadas; senão, fallback para as fotos do
-- fc_snapshot (comportamento anterior). Campos novos: ent_real, sai_real, fonte.
create or replace function public.fc_historico(p_dias int default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date as d
),
n_caixa as (select count(*) as n from public.omie_saldos_cc where conta_caixa),
caixa_nomes as (select descricao from public.omie_saldos_cc where conta_caixa),
mov as (
  select e.data, (m->>'nValorDocumento')::numeric as v,
         coalesce(m->>'cCodCategoria','') like '0.01.%' as transf,
         coalesce(m->>'cDesCliente','') as descr
  from public.omie_extrato_dia e
  join public.omie_saldos_cc c on c.n_cod_cc = e.n_cod_cc and c.conta_caixa
  cross join lateral jsonb_array_elements(e.movimentos) m
  where (m->>'nValorDocumento')::numeric <> 0
    and coalesce(m->>'cSituacao', '') <> 'Previsto'
),
movx as (
  -- exclui transferência entre DUAS contas de caixa (remanejamento interno);
  -- transferência vinda de conta não-caixa (Mercado Pago, Shopee…) é entrada real
  select * from mov m
  where not (m.transf
    and exists (select 1 from caixa_nomes cn
                where trim(regexp_replace(m.descr, '^Transf\.\s*(.*?)\s*&gt;&gt;.*$', '\1')) = cn.descricao)
    and exists (select 1 from caixa_nomes cn
                where trim(regexp_replace(m.descr, '^.*&gt;&gt;\s*(.*)$', '\1')) = cn.descricao))
),
ext_fluxo as (
  select data,
         coalesce(sum(v) filter (where v > 0), 0)::numeric(14,2) as ent_real,
         coalesce(-sum(v) filter (where v < 0), 0)::numeric(14,2) as sai_real
  from movx group by data
),
ext as (
  select e.data, sum(e.saldo_fim)::numeric(14,2) as fechamento_ext, count(*) as contas
  from public.omie_extrato_dia e
  join public.omie_saldos_cc c on c.n_cod_cc = e.n_cod_cc and c.conta_caixa
  group by e.data
),
snap as (
  select data, saldo_caixa,
         (curva->0->>'entradas')::numeric as ent_prev,
         (curva->0->>'saidas')::numeric   as sai_prev,
         lead(data)        over (order by data) as fechamento_data,
         lead(saldo_caixa) over (order by data) as fechamento
  from public.fc_snapshot
),
dias as (
  select coalesce(e.data, s.data) as data,
         s.saldo_caixa as abertura,
         s.ent_prev, s.sai_prev,
         s.fechamento as fech_foto, s.fechamento_data as fech_foto_data,
         case when e.contas = (select n from n_caixa) then e.fechamento_ext end as fech_ext,
         f.ent_real, f.sai_real
  from ext e
  full join snap s using (data)
  left join ext_fluxo f on f.data = coalesce(e.data, s.data)
)
select jsonb_build_object(
  'referencia', (select d from hoje),
  'dias', coalesce((
    select jsonb_agg(jsonb_build_object(
      'data',            x.data,
      'abertura',        x.abertura,
      'fechamento',      coalesce(x.fech_ext, x.fech_foto),
      'fonte',           case when x.fech_ext is not null then 'extrato'
                              when x.fech_foto is not null then 'foto' end,
      'fechamento_data', case when x.fech_ext is not null then x.data else x.fech_foto_data end,
      'ent_real',        case when x.fech_ext is not null then coalesce(x.ent_real, 0) else x.ent_real end,
      'sai_real',        case when x.fech_ext is not null then coalesce(x.sai_real, 0) else x.sai_real end,
      'movimento',       case when x.fech_ext is not null
                              then round(coalesce(x.ent_real, 0) - coalesce(x.sai_real, 0), 2)
                              else round(x.fech_foto - x.abertura, 2) end,
      'ent_prev',        round(x.ent_prev, 2),
      'sai_prev',        round(x.sai_prev, 2)
    ) order by x.data)
    from dias x, hoje h
    where x.data < h.d and (p_dias is null or x.data >= h.d - p_dias)
  ), '[]'::jsonb)
);
$function$;

comment on function public.fc_historico(int) is
'Dias passados do F.C. Projetado. Desde 26/08/2026 fecha pelo EXTRATO da Omie (omie_extrato_dia): ent_real/sai_real = créditos/débitos reais do dia nas contas de caixa (transferência entre duas contas de caixa excluída — remanejamento interno) e fechamento = Σ saldo de fim de dia (fonte=extrato, identidade exata por construção). Dia sem extrato completo cai na foto do fc_snapshot (fonte=foto, só movimento líquido). ent_prev/sai_prev = o que a curva projetava (backtest). Default p_dias=NULL = todo o histórico.';

-- Cron: o extrato roda junto do omie-saldos (08:30/16:30 BRT), janela de 5 dias.
select cron.alter_job(
  (select jobid from cron.job where jobname = 'omie-saldos'),
  command => $$SET statement_timeout='400s'; SELECT public.omie_fill_saldos(); SELECT public.omie_fill_extrato(5);$$
);
