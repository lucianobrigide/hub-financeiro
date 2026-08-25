-- Saídas projetadas: agendar pela PREVISÃO DE PAGAMENTO, não pelo vencimento
-- (decisão do Luciano 25/08/2026: "você deve pegar a coluna previsão de
-- pagamento, não vencimento").
--
-- A Omie tem `data_previsao` (formato DD/MM/YYYY no raw): a data que o
-- financeiro PROGRAMA para pagar — que é o fato relevante para o caixa.
-- Medido em 25/08/2026: 668/668 títulos abertos têm previsão; em 148 deles
-- (R$ 3,23M) ela difere do vencimento. Caso que motivou a mudança: 2 títulos
-- MARPAL (venc. 27 e 28/08, R$ 90,5k) programados para 05/09 — pelo
-- vencimento apareciam na semana errada.
--
-- Régua: TODA a classificação (cronograma, exigível, corte ago/2026, legado,
-- grupos, após-90d) passa a usar `prev = coalesce(data_previsao, data_vencimento)`.
-- Título vencido mas REPROGRAMADO pelo financeiro volta ao cronograma na data
-- programada (deixa de ser "vencido exigível"). O vencimento original segue
-- no payload (`titulos[].venc`) e a UI o mostra quando difere da previsão.
-- Baldes em 25/08 com a régua nova: futuro R$ 3,78M (394) · previsto desde
-- ago e não pago R$ 35,3k (18) · legado pré-ago R$ 7,6M (256, inalterado).

create or replace function public.omie_saidas_projetadas()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date d
),
corte as (
  select date '2026-08-01' d  -- decisão do Luciano 25/08/2026; mudar aqui se a régua mudar
),
ab as (
  select d.codigo_lancamento_omie, d.codigo_cliente_fornecedor, d.codigo_categoria,
         d.valor, d.data_vencimento, d.status_titulo,
         -- a data que agenda o caixa: previsão de pagamento (fallback: vencimento)
         coalesce(to_date(nullif(d.raw->>'data_previsao',''), 'DD/MM/YYYY'), d.data_vencimento) as prev,
         d.fornecedor_nome, d.numero_documento,
         nullif(d.raw->>'numero_parcela','') as parcela,
         case
           when d.codigo_categoria = '2.01.01' then 'Compras de mercadoria'
           when d.codigo_categoria = '2.01.96' then 'Plataformas / serviços essenciais'
           when d.codigo_categoria is null and d.codigo_cliente_fornecedor = 10705160510 then 'DIFAL BA (parcelamento)'
           else coalesce(m.dre_label, 'Sem categoria na Omie')
         end as grupo
  from omie_despesas d
  left join omie_dre_mapa m on m.codigo_categoria = d.codigo_categoria
  where d.ausente_desde is null
    -- exclui só o morto; "VENCE HOJE" e qualquer status novo ENTRAM (fix 25/08/2026)
    and d.status_titulo not in ('PAGO', 'CANCELADO')
    and d.data_vencimento is not null
    and d.valor is not null
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
  'atualizado_em', (select max(updated_at) from omie_despesas)
);
$function$;

comment on function public.omie_saidas_projetadas() is
'Saídas projetadas do F.C. (contas a pagar em aberto na Omie). Agendadas pela PREVISÃO DE PAGAMENTO (coalesce(data_previsao, data_vencimento) — decisão do Luciano 25/08/2026); vencimento original segue em titulos[].venc. Corte FIXO em 01/08/2026 sobre a previsão: previsto desde ago e não pago = exigível; anterior = legado fora do total. Filtro por EXCLUSÃO (fix VENCE HOJE 25/08/2026): entra tudo que não é PAGO/CANCELADO. Devolve `titulos` para o drill-down por dia na UI.';
