-- ═══════════════════════════════════════════════════════════════════════════
-- Saídas projetadas: despesa de CARTÃO DE CRÉDITO sai na DATA DA FATURA
-- (28/08/2026, decisão do Luciano: "se são despesas do cartão de crédito,
-- coloque no fluxo de caixa na data em que pagamos a fatura")
--
-- Fatos medidos antes de ligar:
--  · Todo título de cartão na Omie aponta `raw->id_conta_corrente` para uma
--    conta tipo 'CR' (4 cartões: Itaú MasterCard 8545, Visa Empresarial
--    2431/2439, PagBank Visa 6710).
--  · O caixa real sai na TRANSFERÊNCIA conta de caixa → cartão (categoria
--    0.01.02 no extrato; ago: MasterCard pago 11/08, Visa 2439 pago 10/08) —
--    essa perna JÁ conta como saída real na curva (conta CR não é interna).
--  · Dia da fatura ("melhor esforço", decisão do Luciano 28/08): dia do ÚLTIMO
--    pagamento observado no extrato para aquele cartão, fallback dia 10 —
--    auto-ajusta a cada fatura nova que aparecer no extrato.
--
-- Régua: título de conta CR ganha data projetada = PRÓXIMA ocorrência do dia
-- da fatura do cartão estritamente depois de greatest(previsão, ontem) —
-- nunca no passado, então cartão NUNCA entra em "vencido" (Claude AI venc.
-- 16/08 não é conta atrasada; entra na fatura de 11/09). Grupo vira
-- "Cartão de crédito — <cartão>" (drill-down do dia mostra a composição).
-- Aproximação conhecida: despesa lançada poucos dias antes do pagamento pode
-- cair na fatura seguinte na vida real (fechamento não é conhecido) — erro a
-- favor do caixa (projeta a saída mais cedo).
-- Consequência: títulos de cartão saem do histórico previsional (a saída real
-- do passado é a transferência da fatura, já medida pelo extrato) — a
-- identidade "Σ abertos do histórico ≡ vencido_recente" continua valendo.
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
-- dia de pagamento da fatura por cartão: dia do último pagamento visto no
-- extrato (transf. conta de caixa → cartão); fallback 10 (o mais cedo medido)
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
base0 as (
  select d.codigo_lancamento_omie, d.codigo_cliente_fornecedor, d.codigo_categoria,
         d.valor, d.data_vencimento, d.status_titulo,
         coalesce(to_date(nullif(d.raw->>'data_previsao',''), 'DD/MM/YYYY'), d.data_vencimento) as prev0,
         d.fornecedor_nome, d.numero_documento,
         nullif(d.raw->>'numero_parcela','') as parcela,
         (d.status_titulo = 'PAGO') as pago,
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
         b.valor, b.data_vencimento, b.status_titulo,
         -- cartão de crédito: data = próxima fatura do cartão APÓS greatest(previsão, ontem)
         case when fd.n_cod_cc is not null then
           case when date_trunc('month', greatest(b.prev0, h.d - 1))::date + (fd.dia - 1)
                     > greatest(b.prev0, h.d - 1)
                then date_trunc('month', greatest(b.prev0, h.d - 1))::date + (fd.dia - 1)
                else (date_trunc('month', greatest(b.prev0, h.d - 1)) + interval '1 month')::date + (fd.dia - 1)
           end
         else b.prev0 end as prev,
         b.fornecedor_nome, b.numero_documento, b.parcela, b.pago,
         case when fd.n_cod_cc is not null
              then 'Cartão de crédito — ' || fd.descricao
              else b.grupo0 end as grupo
  from base0 b
  cross join hoje h
  left join fatura_dia fd on fd.n_cod_cc = b.id_cc
),
ab as (
  select * from base where not pago
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
'Saídas projetadas do F.C. (contas a pagar Omie, previsão de pagamento, corte fixo 01/08/2026). Desde 28/08/2026: título de CARTÃO DE CRÉDITO (id_conta_corrente → conta tipo CR) é projetado na PRÓXIMA data de fatura do cartão (dia = último pagamento de fatura visto no extrato, fallback 10; auto-ajusta), grupo "Cartão de crédito — <cartão>", e nunca conta como vencido — o caixa real sai na transferência banco→cartão, que o extrato já mede.';
