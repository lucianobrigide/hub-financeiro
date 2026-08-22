-- Amazon — recebíveis: data DERIVADA para o ciclo aberto · 22/08/2026
--
-- Pedido do Luciano (22/08): cronograma com data em TODAS as plataformas.
-- Até aqui o ciclo corrente (grupo Open) entrava no total SEM data, porque a
-- Amazon não publica quando ele fecha. Mas a grade é um FATO da própria Amazon,
-- medido em az_finance_groups (37 grupos): todo grupo abre e fecha numa grade
-- fixa de 14 dias (sempre 2ª-feira 12:39 BRT: 20/07 → 03/08 → 17/08 → 31/08…) e
-- `FundTransferDate` = exatamente o fechamento (lag 0,00 em 22/22 Succeeded).
-- Dos grupos positivos já fechados, 15/22 fecharam em 14 dias exatos e 5/5 dos
-- acima de R$ 2k; os que estenderam (28/42/84d) eram grupos pequenos (<R$ 1k) —
-- a Amazon rola saldo pequeno/negativo para o ciclo seguinte.
--
-- Régua v2: grupo Open com total > 0 → data = início + 14 dias (nunca no passado;
-- se já passou e segue aberto, = hoje). Grupo Open negativo/zero segue SEM data
-- (vai ser abatido do próximo ciclo — não é entrada). A acurácia da grade é
-- medida na própria RPC (`acuracia_14d` = % do VALOR dos grupos positivos
-- fechados que fechou em 14d exatos) e vai no selo do card.
create or replace function public.az_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  -- Dinheiro a caminho do banco: fechado e com transferência em processamento.
  transito as (
    select (transfer_date at time zone 'America/Sao_Paulo')::date as dia,
           round(sum(total),2) as valor
    from az_finance_groups
    where processing_status = 'Closed'
      and transfer_status = 'Processing'
      and transfer_date is not null
    group by 1
  ),
  -- Ciclo corrente POSITIVO: valor real; data = fechamento da grade de 14 dias.
  aberto_pos as (
    select greatest(((grupo_inicio + interval '14 days') at time zone 'America/Sao_Paulo')::date, h.d) as dia,
           round(sum(total),2) as valor, count(*) as grupos
    from az_finance_groups, hoje h
    where processing_status = 'Open' and coalesce(total,0) > 0
    group by 1
  ),
  -- Ciclo corrente NEGATIVO/zero: abate o próximo ciclo — sem data, fora do cronograma.
  aberto_neg as (
    select coalesce(round(sum(total),2), 0) as valor, count(*) as grupos
    from az_finance_groups
    where processing_status = 'Open' and coalesce(total,0) < 0
  ),
  -- Acurácia da grade: grupos positivos já fechados que fecharam em 14 dias exatos.
  grade as (
    select count(*) as grupos,
           round(100.0 * coalesce(sum(total) filter (where round(extract(epoch from (grupo_fim - grupo_inicio))/86400) = 14), 0)
                 / nullif(sum(total), 0), 1) as acuracia_valor,
           count(*) filter (where round(extract(epoch from (grupo_fim - grupo_inicio))/86400) = 14) as grupos_14d
    from az_finance_groups
    where processing_status = 'Closed' and coalesce(total,0) > 0 and grupo_fim is not null
  ),
  dias as (
    select dia, round(sum(valor),2) as valor
    from (select dia, valor from transito union all select dia, valor from aberto_pos) u
    group by dia
  )
  select jsonb_build_object(
    'referencia',    (select d from hoje),
    'total',         coalesce((select sum(valor) from transito),0)
                     + coalesce((select sum(valor) from aberto_pos),0)
                     + (select valor from aberto_neg),
    'em_transito',   coalesce((select sum(valor) from transito),0),
    -- Ciclo aberto positivo: agora COM data (fechamento da grade).
    'ciclo_aberto',  coalesce((select sum(valor) from aberto_pos),0),
    'ciclo_fecha_em',(select min(dia) from aberto_pos),
    -- Só o negativo fica sem data (abate o próximo repasse).
    'sem_data',      (select valor from aberto_neg),
    'grupos_abertos',(select coalesce(sum(grupos),0) from aberto_pos) + (select grupos from aberto_neg),
    'acuracia_14d',  (select acuracia_valor from grade),
    'grupos_14d',    (select grupos_14d from grade),
    'base_grade',    (select grupos from grade),
    'atualizado_em', (select max(atualizado_em) from az_finance_groups),
    'dias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', dia, 'valor', valor) order by dia)
       from dias where valor <> 0),
      '[]'::jsonb)
  );
$$;

comment on function public.az_recebiveis() is
  'Recebíveis Amazon: grupos Closed+Processing (data real de transferência) + ciclo aberto positivo com data DERIVADA = início + 14d (grade fixa da Amazon, medida: FundTransferDate = fechamento em 22/22; 15/22 grupos positivos fecham em 14d exatos, 5/5 acima de R$ 2k). Ciclo aberto negativo = sem data (abate o próximo).';
