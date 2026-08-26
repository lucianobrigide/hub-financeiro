-- Saídas projetadas: HISTÓRICO — os dias passados do cronograma ficam visíveis
-- (pedido do Luciano 26/08/2026: "no cronograma de saídas você retirou o dia 25;
--  preciso conseguir ver quais foram as saídas dos dias passados").
--
-- Régua do passado: cada dia D < hoje (desde o corte 01/08/2026) mostra os
-- títulos cuja PREVISÃO DE PAGAMENTO era D — a mesma régua que agenda o futuro
-- — com o STATUS REAL de cada um: `pago` (baixado na Omie, saiu) ou em aberto
-- (segue no exigível de D+0). Título reprogramado para frente sai do dia
-- passado e aparece na nova data (correto: não saiu naquele dia).
--
-- ⚠️ Por que não usamos a DATA DE PAGAMENTO: a ListarContasPagar deixou de
-- devolver esse campo (`omie_despesas.data_pagamento` parou de preencher em
-- ~20/07/2026; o raw de título pago hoje não traz nenhuma data de baixa).
-- "Pago" aqui = status atual do título, não prova de que saiu NAQUELE dia —
-- normalmente a baixa acontece no próprio dia ou 1-2 dias depois da previsão.
--
-- Novos campos no retorno: `historico` (um item por dia passado: pago/aberto/
-- títulos) e `historico_titulos` (detalhe por título, flag `pago`). Todo o
-- resto do contrato fica intacto.

create or replace function public.omie_saidas_projetadas()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date d
),
corte as (
  select date '2026-08-01' d
),
base as (
  select d.codigo_lancamento_omie, d.codigo_cliente_fornecedor, d.codigo_categoria,
         d.valor, d.data_vencimento, d.status_titulo,
         coalesce(to_date(nullif(d.raw->>'data_previsao',''), 'DD/MM/YYYY'), d.data_vencimento) as prev,
         d.fornecedor_nome, d.numero_documento,
         nullif(d.raw->>'numero_parcela','') as parcela,
         (d.status_titulo = 'PAGO') as pago,
         case
           when d.codigo_categoria = '2.01.01' then 'Compras de mercadoria'
           when d.codigo_categoria = '2.01.96' then 'Plataformas / serviços essenciais'
           when d.codigo_categoria is null and d.codigo_cliente_fornecedor = 10705160510 then 'DIFAL BA (parcelamento)'
           else coalesce(m.dre_label, 'Sem categoria na Omie')
         end as grupo
  from omie_despesas d
  left join omie_dre_mapa m on m.codigo_categoria = d.codigo_categoria
  where d.ausente_desde is null
    and d.status_titulo <> 'CANCELADO'
    and d.data_vencimento is not null
    and d.valor is not null
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
      'pago', h.pago
    ) order by h.prev, h.valor desc)
    from hist h left join omie_fornecedores fo on fo.codigo_cliente = h.codigo_cliente_fornecedor), '[]'::jsonb),
  'atualizado_em', (select max(updated_at) from omie_despesas)
);
$function$;

comment on function public.omie_saidas_projetadas() is
'Saídas projetadas do F.C. (contas a pagar da Omie em aberto), agendadas pela PREVISÃO DE PAGAMENTO, com corte fixo 01/08/2026 e, desde 26/08/2026, HISTÓRICO dos dias passados (previsto no dia + status real pago/aberto por título — a API não devolve data de baixa). Ver migrations 20260821120001..20260826140001.';
