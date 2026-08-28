-- ═══════════════════════════════════════════════════════════════════════════
-- omie_saidas_projetadas: valor por título = SALDO ABERTO real (28/08/2026)
-- (sequência da 20260828170001/170002 — casos do Luciano: NF 2282 Firenze,
-- saldo R$ 29.000 após crédito de NF de devolução; NF 3954 Arnix, saldo
-- R$ 17.040 após desconto financeiro; ambos status "PAGO" no ListarContasPagar)
--
-- Régua: efetivo = coalesce(valor_aberto, PAGO→0, senão valor). Título com
-- efetivo > 0 entra na projeção PELO SALDO (mesmo status PAGO); efetivo = 0
-- sai. Sem valor_aberto sincronizado, comportamento idêntico ao anterior.
-- Bônus da 1ª sincronização: além dos 2 casos, apareceram mais 4 títulos
-- "PAGO" com saldo (maior: INTERM 9742828, R$ 183.308,71 em aberto de
-- R$ 183.447,18 — baixa de 28/08 quase sem valor aplicado; conferir com a
-- Fernanda se era para estar liquidado).
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.omie_saidas_projetadas()
returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date d
),
corte as (
  select date '2026-08-01' d
),
cartoes as (
  select n_cod_cc, descricao from omie_saldos_cc where tipo = 'CR'
),
fatura_dia as (
  select ct.n_cod_cc, ct.descricao,
         coalesce((
           select extract(day from e.data)::int
           from omie_extrato_dia e
           join omie_saldos_cc cx on cx.n_cod_cc = e.n_cod_cc and cx.conta_caixa
           cross join lateral jsonb_array_elements(e.movimentos) m
           where coalesce(m->>'cCodCategoria','') like '0.01.%'
             and (m->>'nValorDocumento')::numeric < 0
             and trim(regexp_replace(m->>'cDesCliente', '^.*&gt;&gt;\s*(.*)$', '\1')) = ct.descricao
           order by e.data desc limit 1
         ), 10) as dia
  from cartoes ct
),
-- saldo já lançado no cartão (títulos baixados aguardando fatura) → item
-- sintético "Fatura <cartão>" na próxima data de fatura
fatura_acum as (
  select fd.n_cod_cc, fd.descricao,
         (-c.saldo_atual)::numeric as valor,
         case when date_trunc('month', h.d - 1)::date + (fd.dia - 1) > h.d - 1
              then date_trunc('month', h.d - 1)::date + (fd.dia - 1)
              else (date_trunc('month', h.d - 1) + interval '1 month')::date + (fd.dia - 1)
         end as data
  from fatura_dia fd
  join omie_saldos_cc c on c.n_cod_cc = fd.n_cod_cc
  cross join hoje h
  where c.saldo_atual < 0
),
base0 as (
  select d.codigo_lancamento_omie, d.codigo_cliente_fornecedor, d.codigo_categoria,
         d.valor, d.data_vencimento, d.status_titulo,
         coalesce(to_date(nullif(d.raw->>'data_previsao',''), 'DD/MM/YYYY'), d.data_vencimento) as prev0,
         d.fornecedor_nome, d.numero_documento,
         nullif(d.raw->>'numero_parcela','') as parcela,
         -- saldo ABERTO real (PesquisarLancamentos): baixa parcial por crédito/
         -- desconto deixa status PAGO com aberto > 0 — o saldo continua devido
         coalesce(d.valor_aberto, case when d.status_titulo = 'PAGO' then 0 else d.valor end) as efetivo,
         (d.raw->>'id_conta_corrente')::bigint as id_cc,
         case
           when d.codigo_categoria = '2.01.01' then 'Compras de mercadoria'
           when d.codigo_categoria = '2.01.96' then 'Plataformas / serviços essenciais'
           when d.codigo_categoria is null and d.codigo_cliente_fornecedor = 10705160510 then 'DIFAL BA (parcelamento)'
           else coalesce(m.dre_label, 'Sem categoria na Omie')
         end as grupo0
  from omie_despesas d
  left join omie_dre_mapa m on m.codigo_categoria = d.codigo_categoria
  where d.ausente_desde is null
    and d.status_titulo <> 'CANCELADO'
    and d.data_vencimento is not null
    and d.valor is not null
),
base as (
  select b.codigo_lancamento_omie, b.codigo_cliente_fornecedor, b.codigo_categoria,
         case when b.efetivo > 0.005 then b.efetivo else b.valor end as valor,
         b.data_vencimento, b.status_titulo,
         case when fd.n_cod_cc is not null then
           case when date_trunc('month', greatest(b.prev0, h.d - 1))::date + (fd.dia - 1)
                     > greatest(b.prev0, h.d - 1)
                then date_trunc('month', greatest(b.prev0, h.d - 1))::date + (fd.dia - 1)
                else (date_trunc('month', greatest(b.prev0, h.d - 1)) + interval '1 month')::date + (fd.dia - 1)
           end
         else b.prev0 end as prev,
         b.fornecedor_nome, b.numero_documento, b.parcela,
         (b.efetivo <= 0.005) as pago,
         case when fd.n_cod_cc is not null
              then 'Cartão de crédito — ' || fd.descricao
              else b.grupo0 end as grupo
  from base0 b
  cross join hoje h
  left join fatura_dia fd on fd.n_cod_cc = b.id_cc
),
ab as (
  select codigo_lancamento_omie, codigo_cliente_fornecedor, codigo_categoria,
         valor, data_vencimento, status_titulo, prev,
         fornecedor_nome, numero_documento, parcela, pago, grupo
  from base where not pago
  union all
  -- fatura acumulada: despesa JÁ baixada no cartão, caixa sai na fatura
  select null::bigint, null::bigint, null::text,
         fa.valor, fa.data, 'FATURA', fa.data,
         'Fatura ' || fa.descricao, 'saldo já lançado no cartão (Omie)', null, false,
         'Cartão de crédito — ' || fa.descricao
  from fatura_acum fa
),
fut as (select ab.* from ab, hoje where ab.prev >= hoje.d),
venc_rec as (select ab.* from ab, hoje, corte where ab.prev < hoje.d and ab.prev >= corte.d),
venc_ant as (select ab.* from ab, corte where ab.prev < corte.d),
dias as (
  select prev as data, sum(valor) as valor, count(*) as titulos
  from fut, hoje
  where prev < hoje.d + 90
  group by prev
),
tit as (
  select f.prev, f.data_vencimento, f.fornecedor_nome, f.codigo_cliente_fornecedor, f.grupo,
         f.valor, f.numero_documento, f.parcela, false as vencido
  from fut f, hoje
  where f.prev < hoje.d + 90
  union all
  select v.prev, v.data_vencimento, v.fornecedor_nome, v.codigo_cliente_fornecedor, v.grupo,
         v.valor, v.numero_documento, v.parcela, true
  from venc_rec v
),
grupos as (
  select g.grupo,
         coalesce(sum(g.valor) filter (where g.origem = 'fut'), 0)::numeric(14,2) as valor_90d,
         coalesce(sum(g.valor) filter (where g.origem = 'rec'), 0)::numeric(14,2) as vencido_recente,
         count(*) filter (where g.origem = 'fut') as titulos_90d
  from (
    select grupo, valor, 'fut' origem from fut, hoje where prev < hoje.d + 90
    union all
    select grupo, valor, 'rec' from venc_rec
  ) g
  group by g.grupo
),
forn_ant as (
  select coalesce(f.razao_social, v.codigo_cliente_fornecedor::text) as fornecedor,
         sum(v.valor)::numeric(14,2) as valor, count(*) as titulos,
         min(v.prev) as desde
  from venc_ant v left join omie_fornecedores f on f.codigo_cliente = v.codigo_cliente_fornecedor
  group by 1 order by sum(v.valor) desc limit 8
),
hist as (
  select b.* from base b, hoje, corte
  where b.prev < hoje.d and b.prev >= corte.d
),
hist_dias as (
  select prev as data,
         coalesce(sum(valor) filter (where pago), 0)::numeric(14,2) as pago,
         coalesce(sum(valor) filter (where not pago), 0)::numeric(14,2) as aberto,
         count(*) as titulos
  from hist
  group by prev
)
select jsonb_build_object(
  'referencia', (select to_char(d, 'YYYY-MM-DD') from hoje),
  'corte', (select to_char(d, 'YYYY-MM-DD') from corte),
  'total_com_data', coalesce((select sum(valor) from fut), 0)::numeric(14,2),
  'titulos_com_data', (select count(*) from fut),
  'com_data_90d', coalesce((select sum(valor) from dias), 0)::numeric(14,2),
  'apos_90d', jsonb_build_object(
     'valor', coalesce((select sum(valor) from fut, hoje where prev >= hoje.d + 90), 0)::numeric(14,2),
     'titulos', (select count(*) from fut, hoje where prev >= hoje.d + 90),
     'ate', (select to_char(max(prev), 'YYYY-MM-DD') from fut)),
  'vencido_recente', jsonb_build_object(
     'valor', coalesce((select sum(valor) from venc_rec), 0)::numeric(14,2),
     'titulos', (select count(*) from venc_rec),
     'desde', (select to_char(min(prev), 'YYYY-MM-DD') from venc_rec)),
  'vencido_antigo', jsonb_build_object(
     'valor', coalesce((select sum(valor) from venc_ant), 0)::numeric(14,2),
     'titulos', (select count(*) from venc_ant),
     'desde', (select to_char(min(prev), 'YYYY-MM-DD') from venc_ant),
     'fornecedores', coalesce((select jsonb_agg(to_jsonb(forn_ant)) from forn_ant), '[]'::jsonb)),
  'dias', coalesce((select jsonb_agg(jsonb_build_object('data', to_char(data, 'YYYY-MM-DD'), 'valor', valor::numeric(14,2), 'titulos', titulos) order by data) from dias), '[]'::jsonb),
  'titulos', coalesce((select jsonb_agg(jsonb_build_object(
      'prev', to_char(t.prev, 'YYYY-MM-DD'),
      'venc', to_char(t.data_vencimento, 'YYYY-MM-DD'),
      'fornecedor', coalesce(nullif(trim(t.fornecedor_nome), ''), fo.razao_social, t.codigo_cliente_fornecedor::text),
      'grupo', t.grupo,
      'valor', t.valor::numeric(14,2),
      'doc', nullif(trim(t.numero_documento), ''),
      'parcela', t.parcela,
      'vencido', t.vencido
    ) order by t.prev, t.valor desc)
    from tit t left join omie_fornecedores fo on fo.codigo_cliente = t.codigo_cliente_fornecedor), '[]'::jsonb),
  'grupos', coalesce((select jsonb_agg(to_jsonb(grupos) order by (valor_90d + vencido_recente) desc) from grupos), '[]'::jsonb),
  'historico', coalesce((select jsonb_agg(jsonb_build_object(
      'data', to_char(data, 'YYYY-MM-DD'),
      'pago', pago, 'aberto', aberto, 'titulos', titulos
    ) order by data) from hist_dias), '[]'::jsonb),
  'historico_titulos', coalesce((select jsonb_agg(jsonb_build_object(
      'prev', to_char(h.prev, 'YYYY-MM-DD'),
      'venc', to_char(h.data_vencimento, 'YYYY-MM-DD'),
      'fornecedor', coalesce(nullif(trim(h.fornecedor_nome), ''), fo.razao_social, h.codigo_cliente_fornecedor::text),
      'grupo', h.grupo,
      'valor', h.valor::numeric(14,2),
      'doc', nullif(trim(h.numero_documento), ''),
      'parcela', h.parcela,
      'pago', h.pago,
      'pago_em', to_char(pg.dp, 'YYYY-MM-DD')
    ) order by h.prev, h.valor desc)
    from hist h
    left join omie_fornecedores fo on fo.codigo_cliente = h.codigo_cliente_fornecedor
    left join lateral (
      select max(mc.data_pagamento) as dp
      from omie_mov_cc mc
      where mc.n_cod_titulo = h.codigo_lancamento_omie and mc.ausente_desde is null
    ) pg on true), '[]'::jsonb),
  'atualizado_em', (select max(updated_at) from omie_despesas)
);
$function$;

comment on function public.omie_saidas_projetadas() is
'Saídas projetadas do F.C. (contas a pagar Omie, previsão de pagamento, corte fixo 01/08/2026). Valor por título = SALDO ABERTO real (omie_despesas.valor_aberto, do PesquisarLancamentos) — baixa parcial por crédito/desconto deixa status PAGO com saldo devido, e o saldo entra na projeção (28/08/2026, casos NF 2282/3954). Cartão de crédito: título de conta CR projetado na próxima data de fatura (dia do último pagamento no extrato, fallback 10), nunca vencido; saldo já lançado no cartão entra como "Fatura <cartão>".';
