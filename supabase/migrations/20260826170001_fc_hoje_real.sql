-- F.C. Projetado: HOJE (D+0) = real já ocorrido + projetado restante
-- (pedido do Luciano 26/08/2026: "títulos que eram pra ontem saíram HOJE do
--  banco, e as saídas de hoje estão menores do que deveriam. Preciso sempre
--  dos valores exatos de entradas, saídas e saldos, corrigidos conforme o que
--  de fato ocorreu, pra sempre ter o valor em caixa correto").
--
-- Problema: o D+0 da curva só mostrava o PROJETADO restante — pagamento feito
-- hoje de manhã (ex.: R$ 180,8k dos boletos previstos p/ ontem) já saiu do
-- pendente do AP e não aparecia em lugar nenhum do "hoje".
--
-- Estrutura nova do dia corrente, exposta em `fc_historico` → objeto `hoje`:
--   abertura  = fechamento REAL do último dia fechado pelo extrato (ontem);
--   ent_real / sai_real = movimentos REAIS já ocorridos hoje (extrato parcial
--     do dia, coletado 2×/dia junto do omie-saldos, mesmas exclusões:
--     'Previsto' e transferência entre contas de caixa);
--   completo  = extrato de hoje tem todas as contas de caixa (senão a UI
--     ignora e cai no comportamento antigo — foto das 08:30).
-- A UI soma real + projetado restante no D+0. Coerência: pagamento baixado no
-- AP some do projetado no MESMO cron que o débito entra no extrato — sem dupla
-- contagem no instante da coleta (deriva intradiária entre coletas se corrige
-- na próxima passada).
--
-- Bônus (mesma sessão): `omie_saidas_projetadas.historico_titulos` ganha
-- `pago_em` = data REAL do pagamento ("Último Pagamento" da Omie), via
-- omie_mov_cc.n_cod_titulo → data_pagamento (sincronizado no omie-diario;
-- título pago hoje ganha a data na próxima manhã — até lá vem null).

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
  select e.data, sum(e.saldo_fim)::numeric(14,2) as fechamento_ext, count(*) as contas,
         max(e.coletado_em) as coletado_em
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
         s.saldo_caixa as abertura_foto,
         s.ent_prev, s.sai_prev,
         s.fechamento as fech_foto, s.fechamento_data as fech_foto_data,
         case when e.contas = (select n from n_caixa) then e.fechamento_ext end as fech_ext,
         f.ent_real, f.sai_real
  from ext e
  full join snap s using (data)
  left join ext_fluxo f on f.data = coalesce(e.data, s.data)
),
-- fechamento do último dia já FECHADO pelo extrato completo = abertura de hoje
ult_fechado as (
  select e.fechamento_ext
  from ext e, hoje h, n_caixa n
  where e.data < h.d and e.contas = n.n
  order by e.data desc limit 1
),
hj as (
  select (select d from hoje) as data,
         (select fechamento_ext from ult_fechado) as abertura,
         coalesce((select f.ent_real from ext_fluxo f, hoje h where f.data = h.d), 0) as ent_real,
         coalesce((select f.sai_real from ext_fluxo f, hoje h where f.data = h.d), 0) as sai_real,
         coalesce((select e.contas from ext e, hoje h where e.data = h.d), 0) as contas,
         (select e.coletado_em from ext e, hoje h where e.data = h.d) as coletado_em
)
select jsonb_build_object(
  'referencia', (select d from hoje),
  'hoje', (select jsonb_build_object(
      'data', hj.data,
      'abertura', hj.abertura,
      'ent_real', hj.ent_real,
      'sai_real', hj.sai_real,
      'completo', hj.contas = (select n from n_caixa) and hj.abertura is not null,
      'coletado_em', hj.coletado_em
    ) from hj),
  'dias', coalesce((
    select jsonb_agg(jsonb_build_object(
      'data',            x.data,
      'abertura',        case when x.fech_ext is not null
                              then round(x.fech_ext - coalesce(x.ent_real, 0) + coalesce(x.sai_real, 0), 2)
                              else x.abertura_foto end,
      'fechamento',      coalesce(x.fech_ext, x.fech_foto),
      'fonte',           case when x.fech_ext is not null then 'extrato'
                              when x.fech_foto is not null then 'foto' end,
      'fechamento_data', case when x.fech_ext is not null then x.data else x.fech_foto_data end,
      'ent_real',        case when x.fech_ext is not null then coalesce(x.ent_real, 0) else x.ent_real end,
      'sai_real',        case when x.fech_ext is not null then coalesce(x.sai_real, 0) else x.sai_real end,
      'movimento',       case when x.fech_ext is not null
                              then round(coalesce(x.ent_real, 0) - coalesce(x.sai_real, 0), 2)
                              else round(x.fech_foto - x.abertura_foto, 2) end,
      'ent_prev',        round(x.ent_prev, 2),
      'sai_prev',        round(x.sai_prev, 2)
    ) order by x.data)
    from dias x, hoje h
    where x.data < h.d and (p_dias is null or x.data >= h.d - p_dias)
  ), '[]'::jsonb)
);
$function$;

comment on function public.fc_historico(int) is
'Dias passados do F.C. + objeto `hoje`. Passado: visão canônica pelo extrato da Omie (abertura, ent_real/sai_real, fechamento; identidade exata; fallback foto). `hoje`: abertura = fechamento real do último dia fechado, ent_real/sai_real = movimentos JÁ ocorridos hoje (extrato parcial, 2×/dia) — a UI soma com o projetado restante no D+0. Default p_dias=NULL = todo o histórico.';

-- Saídas projetadas: data REAL de pagamento por título no histórico
-- (omie_mov_cc.data_pagamento = "Último Pagamento" da Omie, extrato bancário).
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
'Saídas projetadas do F.C. (contas a pagar da Omie em aberto), agendadas pela PREVISÃO DE PAGAMENTO, corte fixo 01/08/2026, com histórico dos dias passados (previsto no dia + status pago/aberto por título; `pago_em` = data REAL do pagamento via omie_mov_cc quando já sincronizada). Ver migrations 20260821120001..20260826170001.';
