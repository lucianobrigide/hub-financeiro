-- ============================================================================
-- SHEIN — recebíveis (F.C. Projetado) · 17/08/2026
-- ============================================================================
-- A SHEIN é o 2º canal com DATA (o 1º é o Mercado Pago), mas o cronograma é
-- PARCIAL, como o da Amazon — e por um motivo diferente:
--   · O check order (shein_settlement) traz `estimate_pay_time`: a data que a
--     PRÓPRIA SHEIN estima para pagar. check_status 1 = aguardando, 3 = pago.
--   · Só que o check order nasce quando o pedido chega ao status 5 (~2 semanas
--     após a venda). Medido em 17/08/2026: pedidos de 0-7 dias têm 6% de
--     cobertura (4 de 68); 8-14 dias, 43%; 15-21 dias, 88%; 22-30 dias, 83%.
-- Logo: pedido novo tem valor real (receita_estimada) mas ainda não tem data.
--
-- Régua:
--   COM data  = Σ valor_estimado dos check orders com check_status = 1,
--               agrupado por estimate_pay_time (BRT).
--   SEM data  = Σ receita_estimada dos pedidos que AINDA não têm check order
--               (receita > 0, status não-devolução 6/8/9, janela de 60d).
--   total     = os dois. Sem sobreposição: o pedido sai do "sem data" no
--               instante em que ganha check order.
--
-- Por que dá pra somar os dois lados sem medo: a receita_estimada do pedido é o
-- MESMO número do check order. Conferido nos 121 pedidos que já têm os dois
-- lados: 120 batem centavo a centavo (R$ 15.120,62 × R$ 15.322,88); o único
-- divergente (GSH1R101W000671, R$ 202,26) é um pedido DEVOLVIDO depois de pago
-- — a receita do pedido foi zerada e o check order já está liquidado.
--
-- 1ª leitura: R$ 10.667,41 com data (17/08, 24/08 e 31/08) + R$ 21.877,81 em
-- 166 pedidos sem check order = R$ 32.545,22.
--
-- Sem cron próprio: shein-diario/shein-semanal já mantêm pedidos e settlement.

create or replace function shein_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with com_data as (
    select (estimate_pay_time at time zone 'America/Sao_Paulo')::date as dia,
           round(sum(valor_estimado),2) as valor
    from shein_settlement
    where check_status = 1            -- 1 = aguardando pagamento
      and estimate_pay_time is not null
    group by 1
  ),
  sem_data as (
    select count(*) as pedidos,
           coalesce(round(sum(p.receita_estimada),2), 0) as valor,
           min(p.payment_time)::date as mais_antigo
    from shein_pedidos p
    where not exists (select 1 from shein_settlement s where s.order_no = p.order_no)
      and coalesce(p.receita_estimada,0) > 0
      and p.order_status not in (6,8,9)      -- devoluções
      and p.payment_time > now() - interval '60 days'
  )
  select jsonb_build_object(
    'referencia',     (now() at time zone 'America/Sao_Paulo')::date,
    'total',          coalesce((select sum(valor) from com_data),0) + (select valor from sem_data),
    'com_data',       coalesce((select sum(valor) from com_data),0),
    'sem_data',       (select valor from sem_data),
    'pedidos_sem_data',(select pedidos from sem_data),
    'mais_antigo',    (select mais_antigo from sem_data),
    'atualizado_em',  greatest(
                        (select max(updated_at) from shein_settlement),
                        (select max(updated_at) from shein_pedidos)
                      ),
    'dias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', dia, 'valor', valor) order by dia)
       from com_data where valor <> 0),
      '[]'::jsonb)
  );
$function$;

comment on function shein_recebiveis() is
  'Recebíveis SHEIN: check orders aguardando pagamento viram cronograma (estimate_pay_time da própria SHEIN); pedidos ainda sem check order entram no total sem data. Cronograma parcial.';

revoke all on function shein_recebiveis() from public, anon, authenticated;
grant execute on function shein_recebiveis() to service_role;
