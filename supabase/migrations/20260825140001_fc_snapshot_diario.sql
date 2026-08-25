-- F.C. Projetado: SNAPSHOT DIÁRIO da projeção (decisão do Luciano 25/08/2026).
--
-- Problema: a página /fc-projetado calcula tudo na hora — a projeção de cada
-- dia evapora. Sem histórico não dá para ver a TENDÊNCIA (o D+30 está
-- melhorando?) nem medir a ACURÁCIA (o saldo projetado para hoje bateu com o
-- caixa real de hoje?) — o mesmo espírito dos detectores dos recebíveis.
--
-- `fc_snapshot_diario()` replica a matemática da curva do client
-- (components/SaldoProjetado.tsx) no banco:
--   saldo(D) = caixa hoje (fc_saldo_caixa, só conta_caixa)
--            + Σ recebíveis COM DATA até D (plataformas que somam; TikTok só
--              se `projetado=true`; dia passado clampa em D+0, igual à UI)
--            − Σ saídas COM DATA até D (omie_saidas_projetadas, 90d)
--            − vencido exigível (desde ago/2026) em D+0
-- e grava uma linha por dia em `fc_snapshot` (re-rodar no mesmo dia substitui).
-- Guarda também a curva inteira (jsonb), o detalhe por plataforma e o que
-- ficou fora da curva — o suficiente para montar depois a UI de tendência e o
-- backtest projetado × realizado sem re-derivar nada.
--
-- Cron `fc-snapshot` às 08:45 BRT (11:45 UTC) — logo após o omie-saldos das
-- 08:30 BRT, quando o dia está com tudo fresco. Log em ml_cron_log job
-- 'fc_snapshot'; no catálogo do crons_status.

create table if not exists public.fc_snapshot (
  data            date primary key,          -- dia da foto (BRT)
  criado_em       timestamptz not null default now(),
  saldo_caixa     numeric(14,2),             -- fc_saldo_caixa().total no momento da foto
  entradas_90d    numeric(14,2) not null,    -- Σ recebíveis com data em D+0..D+90 (plataformas que somam)
  saidas_90d      numeric(14,2) not null,    -- Σ saídas com data em D+0..D+90 + vencido exigível em D+0
  saldo_d30       numeric(14,2),
  saldo_d60       numeric(14,2),
  saldo_d90       numeric(14,2),
  minimo_30_valor numeric(14,2),
  minimo_30_data  date,
  minimo_90_valor numeric(14,2),
  minimo_90_data  date,
  plataformas     jsonb not null,            -- por plataforma: total/com_data/sem_data/fora_do_total
  fora_curva      jsonb not null,            -- sem data, sem cronograma, vencido antigo, saídas >90d…
  curva           jsonb not null             -- [{data, entradas, saidas, saldo}] D+0 e dias com movimento
);
comment on table public.fc_snapshot is
'Foto diária do F.C. Projetado (cron fc-snapshot, 08:45 BRT). Uma linha por dia; re-rodar substitui. Base para tendência do D+30 e backtest projetado × caixa realizado.';

create or replace function public.fc_snapshot_diario()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  j_mp jsonb; j_sp jsonb; j_tt jsonb; j_az jsonb; j_sh jsonb; j_mg jsonb;
  j_sa jsonb; j_sc jsonb;
  v_tt_soma boolean;
  v_dias_ent jsonb;
  v_saldo0 numeric;
  v_curva jsonb; v_ent90 numeric; v_sai90 numeric;
  v_d30 numeric; v_d60 numeric; v_d90 numeric;
  v_min30 numeric; v_min30_data date; v_min90 numeric; v_min90_data date;
  v_ent_alem numeric;
  v_err text;
begin
  begin
    j_mp := public.mp_recebiveis();
    j_sp := public.shopee_recebiveis();
    j_tt := public.tt_recebiveis();
    j_az := public.az_recebiveis();
    j_sh := public.shein_recebiveis();
    j_mg := public.magalu_recebiveis();
    j_sa := public.omie_saidas_projetadas();
    j_sc := public.fc_saldo_caixa();

    v_saldo0  := (j_sc->>'total')::numeric;
    v_tt_soma := coalesce((j_tt->>'projetado')::boolean, false);

    -- Entradas com data das plataformas que somam (TikTok só se projetado).
    v_dias_ent := coalesce(j_mp->'dias','[]'::jsonb)
               || coalesce(j_sp->'dias','[]'::jsonb)
               || coalesce(j_az->'dias','[]'::jsonb)
               || coalesce(j_sh->'dias','[]'::jsonb)
               || case when v_tt_soma then coalesce(j_tt->'dias','[]'::jsonb) else '[]'::jsonb end;

    -- CTAS não substitui variáveis do plpgsql (comando utilitário) — por isso
    -- CREATE vazio + INSERT (DML, onde a substituição funciona).
    create temp table _fc_curva (data date, d int, ent numeric, sai numeric, saldo numeric) on commit drop;
    insert into _fc_curva
    with ent_raw as (
      -- dia no passado clampa em hoje (D+0), igual à UI
      select greatest((d->>'data')::date, v_hoje) as data, (d->>'valor')::numeric as valor
      from jsonb_array_elements(v_dias_ent) d
    ),
    ent90 as (
      select data, sum(valor) as valor from ent_raw where data <= v_hoje + 90 group by 1
    ),
    sai_raw as (
      select (d->>'data')::date as data, (d->>'valor')::numeric as valor
      from jsonb_array_elements(coalesce(j_sa->'dias','[]'::jsonb)) d
      union all
      select v_hoje, coalesce((j_sa->'vencido_recente'->>'valor')::numeric, 0)
    ),
    sai90 as (
      select data, sum(valor) as valor from sai_raw where data <= v_hoje + 90 group by 1
    ),
    serie as (select v_hoje + g as data, g as d from generate_series(0, 90) g)
    select s.data, s.d,
           coalesce(e.valor, 0) as ent,
           coalesce(x.valor, 0) as sai,
           coalesce(v_saldo0, 0)
             + sum(coalesce(e.valor,0) - coalesce(x.valor,0)) over (order by s.d) as saldo
    from serie s
    left join ent90 e using (data)
    left join sai90 x using (data);

    select round(sum(ent), 2), round(sum(sai), 2),
           round(max(saldo) filter (where d = 30), 2),
           round(max(saldo) filter (where d = 60), 2),
           round(max(saldo) filter (where d = 90), 2),
           coalesce(jsonb_agg(jsonb_build_object(
             'data', data, 'entradas', round(ent,2), 'saidas', round(sai,2), 'saldo', round(saldo,2)
           ) order by d) filter (where d = 0 or ent <> 0 or sai <> 0), '[]'::jsonb)
      into v_ent90, v_sai90, v_d30, v_d60, v_d90, v_curva
    from _fc_curva;

    select round(saldo, 2), data into v_min30, v_min30_data
    from _fc_curva where d <= 30 order by saldo asc, d asc limit 1;
    select round(saldo, 2), data into v_min90, v_min90_data
    from _fc_curva order by saldo asc, d asc limit 1;

    select coalesce(round(sum((d->>'valor')::numeric), 2), 0) into v_ent_alem
    from jsonb_array_elements(v_dias_ent) d
    where (d->>'data')::date > v_hoje + 90;

    insert into public.fc_snapshot as s
      (data, criado_em, saldo_caixa, entradas_90d, saidas_90d,
       saldo_d30, saldo_d60, saldo_d90,
       minimo_30_valor, minimo_30_data, minimo_90_valor, minimo_90_data,
       plataformas, fora_curva, curva)
    values (
      v_hoje, now(), v_saldo0, coalesce(v_ent90,0), coalesce(v_sai90,0),
      v_d30, v_d60, v_d90,
      v_min30, v_min30_data, v_min90, v_min90_data,
      jsonb_build_object(
        'mercado-pago', jsonb_build_object('total', j_mp->'total'),
        'shopee',       jsonb_build_object('total', j_sp->'total', 'com_data', j_sp->'com_data', 'sem_data', j_sp->'sem_data'),
        'tiktok',       jsonb_build_object('total', j_tt->'total', 'bruto', j_tt->'bruto', 'projetado', v_tt_soma,
                                           'razao_60d', j_tt->'repasse_mediano_60d', 'fora_do_total', not v_tt_soma),
        'amazon',       jsonb_build_object('total', j_az->'total', 'sem_data', j_az->'sem_data'),
        'shein',        jsonb_build_object('total', j_sh->'total', 'sem_data', j_sh->'sem_data'),
        'magalu',       jsonb_build_object('total', j_mg->'total', 'sem_cronograma', true)
      ),
      jsonb_build_object(
        'recebivel_sem_data',
          coalesce((j_sp->>'sem_data')::numeric,0) + coalesce((j_az->>'sem_data')::numeric,0)
          + coalesce((j_sh->>'sem_data')::numeric,0)
          + case when v_tt_soma then coalesce((j_tt->>'sem_data')::numeric,0) else 0 end,
        'sem_cronograma_magalu', coalesce((j_mg->>'total')::numeric,0),
        'tiktok_fora_do_total',  case when v_tt_soma then 0 else coalesce((j_tt->>'total')::numeric,0) end,
        'entradas_apos_90d',     v_ent_alem,
        'saidas_apos_90d',       coalesce((j_sa->'apos_90d'->>'valor')::numeric,0),
        'vencido_pre_corte',     coalesce((j_sa->'vencido_antigo'->>'valor')::numeric,0)
      ),
      v_curva
    )
    on conflict (data) do update set
      criado_em = excluded.criado_em, saldo_caixa = excluded.saldo_caixa,
      entradas_90d = excluded.entradas_90d, saidas_90d = excluded.saidas_90d,
      saldo_d30 = excluded.saldo_d30, saldo_d60 = excluded.saldo_d60, saldo_d90 = excluded.saldo_d90,
      minimo_30_valor = excluded.minimo_30_valor, minimo_30_data = excluded.minimo_30_data,
      minimo_90_valor = excluded.minimo_90_valor, minimo_90_data = excluded.minimo_90_data,
      plataformas = excluded.plataformas, fora_curva = excluded.fora_curva, curva = excluded.curva;

    drop table _fc_curva;
  exception when others then
    v_err := SQLERRM;
  end;

  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, pedidos, mensagem)
  values (now(), 'fc_snapshot', v_hoje, v_err is null, null,
          case when v_err is null
            then format('saldo hoje %s · D+30 %s · mínimo 30d %s em %s', v_saldo0, v_d30, v_min30, v_min30_data)
            else 'ERRO: ' || v_err end);

  if v_err is not null then
    return jsonb_build_object('ok', false, 'erro', v_err);
  end if;
  return jsonb_build_object('ok', true, 'data', v_hoje, 'saldo_caixa', v_saldo0,
    'saldo_d30', v_d30, 'saldo_d60', v_d60, 'saldo_d90', v_d90,
    'minimo_30', v_min30, 'minimo_30_data', v_min30_data);
end $function$;

revoke all on function public.fc_snapshot_diario() from public, anon, authenticated;
comment on function public.fc_snapshot_diario() is
'Grava a foto diária do F.C. Projetado em fc_snapshot (curva D+0..D+90, saldo D+30/60/90, mínimos, por-plataforma e fora-da-curva). Replica a matemática de components/SaldoProjetado.tsx. Cron fc-snapshot 08:45 BRT; re-rodar no mesmo dia substitui a foto.';

-- Cron: 08:45 BRT (11:45 UTC), depois do omie-saldos (08:30 BRT).
select cron.schedule('fc-snapshot', '45 11 * * *', $$select public.fc_snapshot_diario();$$);

-- Catálogo da página /crons.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';
  if position('fc-snapshot' in v_def) > 0 then
    raise notice 'catálogo já tem fc-snapshot'; return;
  end if;
  v_row := $r$('fc-snapshot','F.C. Projetado','diario','Todo dia às 08:45 BRT',
     'Grava a foto diária do fluxo de caixa projetado (saldo em conta, curva de 90 dias, saldo em D+30/60/90 e mínimo do período) — é o histórico que permite ver a tendência da projeção e medir se o projetado bateu com o caixa real.',
     'honesto', 28, null),
    $r$;
  v_new := replace(v_def, '(''ml-semanal'',''Mercado Livre'',''semanal''', v_row || '(''ml-semanal'',''Mercado Livre'',''semanal''');
  if v_new = v_def then raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado'; end if;
  execute v_new;
end
$do$;
