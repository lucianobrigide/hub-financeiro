-- BUG FIX: títulos "VENCE HOJE" estavam INVISÍVEIS nas saídas projetadas.
--
-- Achado em 25/08/2026 pela pergunta do Luciano ("dia 5/9 temos conta da
-- Aluminio Marpal a pagar, por que não entrou?"): a Omie marca o título que
-- vence NO PRÓPRIO DIA com status "VENCE HOJE" — um valor que o filtro
-- `status_titulo in ('A VENCER','ATRASADO')` não conhecia. Medido no dia do
-- achado: 11 títulos, R$ 542.012,44 (incluindo MARPAL R$ 137.369,52) fora da
-- curva. Sistemático: TODO dia os boletos daquele próprio dia sumiam da
-- projeção (só reapareciam no dia seguinte, como ATRASADO).
--
-- Fix: em vez de allowlist, EXCLUIR só o comprovadamente morto (PAGO,
-- CANCELADO). Status novo/desconhecido passa a ENTRAR por padrão — título em
-- aberto até prova em contrário, erro a favor do caixa (mostrar saída a mais
-- é melhor que sumir com saída em silêncio). Statuses vivos hoje na base:
-- A VENCER, ATRASADO, VENCE HOJE. Único risco conhecido: um futuro
-- "PAGTO PARCIAL" contaria o valor cheio — aceitável (conservador) até
-- aparecer o primeiro caso.
--
-- O fc_snapshot_diario() herda o fix (chama esta função); re-rodar a foto do
-- dia depois de aplicar.

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
fut as (select ab.* from ab, hoje where ab.data_vencimento >= hoje.d),
venc_rec as (select ab.* from ab, hoje, corte where ab.data_vencimento < hoje.d and ab.data_vencimento >= corte.d),
venc_ant as (select ab.* from ab, corte where ab.data_vencimento < corte.d),
dias as (
  select data_vencimento as data, sum(valor) as valor, count(*) as titulos
  from fut, hoje
  where data_vencimento < hoje.d + 90
  group by data_vencimento
),
tit as (
  select f.data_vencimento, f.fornecedor_nome, f.codigo_cliente_fornecedor, f.grupo,
         f.valor, f.numero_documento, f.parcela, false as vencido
  from fut f, hoje
  where f.data_vencimento < hoje.d + 90
  union all
  select v.data_vencimento, v.fornecedor_nome, v.codigo_cliente_fornecedor, v.grupo,
         v.valor, v.numero_documento, v.parcela, true
  from venc_rec v
),
grupos as (
  select g.grupo,
         coalesce(sum(g.valor) filter (where g.origem = 'fut'), 0)::numeric(14,2) as valor_90d,
         coalesce(sum(g.valor) filter (where g.origem = 'rec'), 0)::numeric(14,2) as vencido_recente,
         count(*) filter (where g.origem = 'fut') as titulos_90d
  from (
    select grupo, valor, 'fut' origem from fut, hoje where data_vencimento < hoje.d + 90
    union all
    select grupo, valor, 'rec' from venc_rec
  ) g
  group by g.grupo
),
forn_ant as (
  select coalesce(f.razao_social, v.codigo_cliente_fornecedor::text) as fornecedor,
         sum(v.valor)::numeric(14,2) as valor, count(*) as titulos,
         min(v.data_vencimento) as desde
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
     'valor', coalesce((select sum(valor) from fut, hoje where data_vencimento >= hoje.d + 90), 0)::numeric(14,2),
     'titulos', (select count(*) from fut, hoje where data_vencimento >= hoje.d + 90),
     'ate', (select to_char(max(data_vencimento), 'YYYY-MM-DD') from fut)),
  'vencido_recente', jsonb_build_object(
     'valor', coalesce((select sum(valor) from venc_rec), 0)::numeric(14,2),
     'titulos', (select count(*) from venc_rec),
     'desde', (select to_char(min(data_vencimento), 'YYYY-MM-DD') from venc_rec)),
  'vencido_antigo', jsonb_build_object(
     'valor', coalesce((select sum(valor) from venc_ant), 0)::numeric(14,2),
     'titulos', (select count(*) from venc_ant),
     'desde', (select to_char(min(data_vencimento), 'YYYY-MM-DD') from venc_ant),
     'fornecedores', coalesce((select jsonb_agg(to_jsonb(forn_ant)) from forn_ant), '[]'::jsonb)),
  'dias', coalesce((select jsonb_agg(jsonb_build_object('data', to_char(data, 'YYYY-MM-DD'), 'valor', valor::numeric(14,2), 'titulos', titulos) order by data) from dias), '[]'::jsonb),
  'titulos', coalesce((select jsonb_agg(jsonb_build_object(
      'venc', to_char(t.data_vencimento, 'YYYY-MM-DD'),
      'fornecedor', coalesce(nullif(trim(t.fornecedor_nome), ''), fo.razao_social, t.codigo_cliente_fornecedor::text),
      'grupo', t.grupo,
      'valor', t.valor::numeric(14,2),
      'doc', nullif(trim(t.numero_documento), ''),
      'parcela', t.parcela,
      'vencido', t.vencido
    ) order by t.data_vencimento, t.valor desc)
    from tit t left join omie_fornecedores fo on fo.codigo_cliente = t.codigo_cliente_fornecedor), '[]'::jsonb),
  'grupos', coalesce((select jsonb_agg(to_jsonb(grupos) order by (valor_90d + vencido_recente) desc) from grupos), '[]'::jsonb),
  'atualizado_em', (select max(updated_at) from omie_despesas)
);
$function$;

comment on function public.omie_saidas_projetadas() is
'Saídas projetadas do F.C. (contas a pagar em aberto na Omie). Corte FIXO em 01/08/2026 (decisão do Luciano 25/08/2026): vencido de ago/2026 em diante = exigível; anterior = legado fora do total. Filtro por EXCLUSÃO desde 25/08/2026 (fix VENCE HOJE): entra tudo que não é PAGO/CANCELADO — status desconhecido conta como aberto, erro a favor do caixa. Devolve `titulos` (detalhe por conta a pagar) para o drill-down por dia na UI.';
