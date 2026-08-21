-- F.C. Projetado — Saídas projetadas (contas a pagar da Omie) · 21/08/2026
--
-- Responde: "quanto já está LANÇADO na Omie para sair, e em que dia vence".
-- Fonte: omie_despesas (ListarContasPagar, re-sync completo diário pelo omie-diario).
-- Nada é estimado: só título em aberto (A VENCER / ATRASADO), vivo (ausente_desde
-- IS NULL), pelo valor do documento e pela data de vencimento da Omie.
--
-- Três baldes, separados de propósito (medido em 21/08/2026):
--   • COM DATA  — vence de hoje em diante: é o cronograma (R$ 1,86M nos 90 dias).
--   • VENCIDO RECENTE (até 30 dias) — exigível agora, ainda sem baixa na Omie
--     (R$ 688k; ex.: NFs de alumínio vencidas ontem). Entra no total como
--     "sem data" (D+0 no saldo projetado — o erro é a favor do caixa).
--   • VENCIDO ANTIGO (>30 dias) — R$ 7,55M em 247 títulos, quase tudo NF de
--     compra de distribuidores (2.01.01) vencida há 5–9 meses, dezenas com o
--     MESMO vencimento por fornecedor: título que nunca foi baixado na Omie, não
--     saída futura. FORA do total; aparece na nota (a confirmar com o financeiro).
-- Título PAGO com vencimento futuro (pago antecipado) não entra.
create or replace function public.omie_saidas_projetadas()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
with hoje as (
  select (now() at time zone 'America/Sao_Paulo')::date d
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
venc_rec as (select ab.* from ab, hoje where ab.data_vencimento < hoje.d and ab.data_vencimento >= hoje.d - 30),
venc_ant as (select ab.* from ab, hoje where ab.data_vencimento < hoje.d - 30),
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
$$;

comment on function public.omie_saidas_projetadas() is
  'F.C. Projetado — saídas lançadas na Omie (contas a pagar em aberto). Cronograma por vencimento (90d) + vencido recente (≤30d, exigível agora) + vencido antigo (>30d, FORA do total: títulos nunca baixados). Só o que está lançado: despesas ainda não lançadas (folha futura, impostos a apurar, boletos que ainda não chegaram) NÃO aparecem.';

revoke all on function public.omie_saidas_projetadas() from public, anon;
grant execute on function public.omie_saidas_projetadas() to service_role, authenticated;
