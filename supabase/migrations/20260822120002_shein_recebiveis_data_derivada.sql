-- SHEIN — recebíveis: data DERIVADA para pedidos ainda sem check order · 22/08/2026
--
-- Pedido do Luciano (22/08): cronograma com data em TODAS as plataformas.
--
-- O que a SHEIN publica (fato, medido em 118 check orders com orderReceiptTime):
--   • `businessCompletedTime` do check order = `orderReceiptTime` do pedido (118/118,
--     diferença < 1 min) → o check order nasce na ENTREGA ao cliente.
--   • `estimatePayTime` é SEMPRE 2ª-feira 01:00 BRT (= 12:00 UTC+8) e segue uma
--     regra exata: segunda-feira da (semana UTC+8 em que o pedido foi entregue)
--     + 2 semanas. Bateu 118/118.
-- O que a SHEIN NÃO publica: previsão de entrega ao cliente (`requestDeliveryTime`
-- é o prazo de ENVIO do vendedor; `expectedCollectTime`/`scheduleDeliveryTime` vêm
-- vazios). Todo pedido "sem data" é pré-entrega (status 1 a enviar, 3/4 em
-- trânsito) — 133 pedidos, R$ 18,3k em 21/08.
--
-- Derivação (uma única estimativa NOSSA, medida e com teto a favor do caixa):
--   entrega prevista = envio (`sellerDeliveryTime`; se ainda não enviou, o prazo de
--   envio `requestDeliveryTime`, que é da própria SHEIN) + 12 dias
--   (lag envio→entrega medido: p50 5,2d · p90 9,1d · máx 16,4d, 118 pedidos).
--   data de pagamento = regra exata da SHEIN aplicada à entrega prevista.
--   Backtest nos 213 check orders (teto 12d): 98,3% do VALOR com data derivada
--   >= data real (78 exatos, 131 uma semana DEPOIS, 4 antes); teto 9d daria 88%,
--   teto 14d 100% com 8d de atraso médio — 12d é o equilíbrio (atraso médio 4,4d,
--   a favor do caixa). Como o pagamento é semanal, errar a entrega em poucos dias
--   raramente muda a segunda-feira; quando muda, é para depois.
-- Detector (condição de permanência, como na Shopee): nos check orders com
-- estimate_pay_time e envio conhecidos dos últimos 45 dias, % do VALOR cuja data
-- derivada >= data real da SHEIN (não-otimista). Abaixo de 80% (base mín. 30) o
-- cronograma derivado se suspende sozinho e esses pedidos voltam para "sem data".
create or replace function public.shein_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  params as (select 12 as teto_dias),
  com_data as (
    select (estimate_pay_time at time zone 'America/Sao_Paulo')::date as dia,
           round(sum(valor_estimado),2) as valor, count(*) as pedidos
    from shein_settlement
    where check_status = 1            -- 1 = aguardando pagamento
      and estimate_pay_time is not null
    group by 1
  ),
  -- Pedidos pagos que ainda não geraram check order (pré-entrega).
  pend as (
    select p.order_no, p.order_status, p.receita_estimada, p.payment_time,
           coalesce(nullif(p.raw->>'sellerDeliveryTime','')::timestamptz,
                    nullif(p.raw->>'requestDeliveryTime','')::timestamptz) as envio
    from shein_pedidos p
    where not exists (select 1 from shein_settlement s where s.order_no = p.order_no)
      and coalesce(p.receita_estimada,0) > 0
      and p.order_status not in (6,8,9)      -- devoluções
      and p.payment_time > now() - interval '60 days'
  ),
  -- Regra exata da SHEIN: 2ª-feira 01:00 BRT, 2 semanas após a semana (UTC+8) da entrega.
  deriv as (
    select pe.*,
           greatest(
             (date_trunc('week', (pe.envio + make_interval(days => pa.teto_dias)) at time zone 'Asia/Shanghai')
               + interval '14 days')::date,
             h.d) as data_derivada
    from pend pe, params pa, hoje h
  ),
  -- Detector: check orders recentes com envio conhecido — a derivada bateu (<= real)?
  acc as (
    select count(*) as pedidos,
           coalesce(sum(s.valor_estimado), 0) as valor_total,
           coalesce(sum(s.valor_estimado) filter (
             where (date_trunc('week', (coalesce(nullif(p.raw->>'sellerDeliveryTime','')::timestamptz,
                                                  nullif(p.raw->>'requestDeliveryTime','')::timestamptz)
                                         + make_interval(days => pa.teto_dias)) at time zone 'Asia/Shanghai')
                    + interval '14 days')::date
                   >= (s.estimate_pay_time at time zone 'America/Sao_Paulo')::date), 0) as valor_no_prazo
    from shein_settlement s
    join shein_pedidos p on p.order_no = s.order_no
    cross join params pa
    where s.estimate_pay_time is not null
      and s.inserted_at >= now() - interval '45 days'
      and coalesce(nullif(p.raw->>'sellerDeliveryTime',''), nullif(p.raw->>'requestDeliveryTime','')) is not null
  ),
  gate as (
    select pedidos as base_pedidos,
           case when valor_total > 0 then round((valor_no_prazo / valor_total)::numeric, 4) end as acuracia,
           (pedidos < 30 or (valor_total > 0 and valor_no_prazo / valor_total >= 0.80)) as ativo
    from acc
  ),
  deriv_ok as (select * from deriv where envio is not null and (select ativo from gate)),
  sem_data as (
    select * from deriv where envio is null or not (select ativo from gate)
  ),
  dias as (
    select dia, round(sum(valor),2) as valor
    from (select dia, valor from com_data
          union all
          select data_derivada as dia, receita_estimada as valor from deriv_ok) u
    group by dia
  )
  select jsonb_build_object(
    'referencia',       (select d from hoje),
    'total',            coalesce((select sum(valor) from com_data),0)
                        + coalesce((select sum(receita_estimada) from pend),0),
    'com_data',         coalesce((select sum(valor) from com_data),0),
    'pedidos_check',    coalesce((select sum(pedidos) from com_data),0),
    'derivada',         coalesce((select round(sum(receita_estimada),2) from deriv_ok),0),
    'pedidos_derivada', (select count(*) from deriv_ok),
    'sem_data',         coalesce((select round(sum(receita_estimada),2) from sem_data),0),
    'pedidos_sem_data', (select count(*) from sem_data),
    'mais_antigo',      (select min(payment_time)::date from pend),
    'teto_dias',        (select teto_dias from params),
    'cronograma_ativo', (select ativo from gate),
    'acuracia_45d',     (select acuracia from gate),
    'base_acuracia',    (select base_pedidos from gate),
    'atualizado_em',    greatest(
                          (select max(updated_at) from shein_settlement),
                          (select max(updated_at) from shein_pedidos)
                        ),
    'dias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', dia, 'valor', valor) order by dia)
       from dias where valor <> 0),
      '[]'::jsonb)
  );
$$;

comment on function public.shein_recebiveis() is
  'Recebíveis SHEIN: check orders aguardando (estimate_pay_time da SHEIN) + pedidos pré-entrega com data DERIVADA = regra exata da SHEIN (2ª-feira, 2 semanas após a semana UTC+8 da entrega; 118/118) aplicada a entrega prevista = envio + 12d (teto medido: 98,3% não-otimista). Detector de acurácia 45d (piso 80%) suspende a derivação sozinho.';
