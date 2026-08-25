-- Saídas projetadas: corte FIXO em 01/08/2026 (decisão do Luciano, 25/08/2026:
-- "considerar o contas a pagar a partir de agosto, ou projetado").
--
-- Antes o exigível usava janela MÓVEL de 30 dias (vencido entre hoje−30 e hoje
-- entrava em D+0; mais antigo ficava fora do total). Isso tinha dois problemas:
-- (a) em 25/08 ainda puxava títulos de fim de julho para o exigível; (b) pior,
-- a janela deslizava — em setembro, um título de agosto não pago sairia
-- SOZINHO do exigível para o balde "fora do total", sem ninguém decidir isso.
--
-- Régua nova: vencimento >= 2026-08-01 e < hoje = VENCIDO EXIGÍVEL (entra no
-- total e em D+0 da curva, até ser pago/baixado na Omie); vencimento anterior
-- a agosto = LEGADO, fora do total por decisão (não mais "a confirmar com o
-- financeiro") — segue visível por fornecedor no card. Em 25/08 os números
-- coincidem com a régua antiga (exigível R$ 35.037,96 em 15 títulos, todos de
-- agosto; legado R$ 7.604.475,16 em 256 títulos, o mais novo de 25/07).
--
-- O retorno ganha o campo 'corte' (para a UI exibir a régua). Chaves
-- vencido_recente/vencido_antigo mantidas (contrato do provider inalterado).

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
         case
           when d.codigo_categoria = '2.01.01' then 'Compras de mercadoria'
           when d.codigo_categoria = '2.01.96' then 'Plataformas / serviços essenciais'
           when d.codigo_categoria is null and d.codigo_cliente_fornecedor = 10705160510 then 'DIFAL BA (parcelamento)'
           else coalesce(m.dre_label, 'Sem categoria na Omie')
         end as grupo
  from omie_despesas d
  left join omie_dre_mapa m on m.codigo_categoria = d.codigo_categoria
  where d.ausente_desde is null
    and d.status_titulo in ('A VENCER', 'ATRASADO')
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
  'grupos', coalesce((select jsonb_agg(to_jsonb(grupos) order by (valor_90d + vencido_recente) desc) from grupos), '[]'::jsonb),
  'atualizado_em', (select max(updated_at) from omie_despesas)
);
$function$;

comment on function public.omie_saidas_projetadas() is
'Saídas projetadas do F.C. (contas a pagar em aberto na Omie). Corte FIXO em 01/08/2026 (decisão do Luciano 25/08/2026): vencido de ago/2026 em diante = exigível (entra no total e em D+0 da curva, até ser baixado); vencido antes de ago/2026 = legado fora do total (visível por fornecedor). Substitui a janela móvel de 30 dias, que faria títulos não pagos saírem sozinhos do exigível com o passar do tempo.';
