-- ============================================================================
-- TikTok — recebíveis (F.C. Projetado) · 17/08/2026
-- ============================================================================
-- ⚠️ O TikTok não tem NEM quando NEM quanto (investigado 17/08/2026):
--   · QUANDO não existe: pedido não liquidado devolve total_count=0 e tudo
--     zerado em /finance/202501/orders/{id}/statement_transactions; statements
--     (/finance/202309/statements) só nascem DEPOIS de liquidar; e
--     /finance/202309/payments só lista o que já foi PAGO. Não há previsão.
--   · QUANTO é incerto: o TikTok SUBSIDIA. A receita do vendedor (fin_revenue)
--     foi 104,39% (jun) e 116,93% (jul) do que o cliente pagou, e o settlement
--     sai sobre essa base maior. Resultado: settlement/pago oscilou 84,6%–98,5%
--     por mês (73%–101% por semana). A razão ESTÁVEL é settlement/revenue
--     (81,0% / 84,2% / 84,1%), mas a revenue só é conhecida ao liquidar.
--
-- DECISÃO DO LUCIANO (17/08/2026): o card do TikTok é INFORMATIVO e fica FORA
-- do total consolidado de recebíveis. Mostra o bruto REAL pago pelo cliente e
-- ainda não liquidado, mais a faixa histórica de repasse — sem projetar um
-- número único que a variância não sustenta.
--
-- Sem cron próprio: lê de tt_pedidos, que o tt-diario já mantém.

create or replace function tt_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with pend as (
    select payment_total, create_time
    from tt_pedidos
    where order_status not in ('CANCELLED','UNPAID')
      and not fin_filled
      and payment_total is not null
  ),
  hist as (
    -- Repasse realizado por mês (só meses com massa mínima, pra um mês de 1
    -- pedido não virar "faixa"). Base: pedidos que JÁ liquidaram.
    select to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM') as mes,
           sum(fin_settlement) / nullif(sum(payment_total),0) * 100 as pct,
           count(*) as n
    from tt_pedidos
    where fin_filled and fin_settlement is not null
      and order_status not in ('CANCELLED','UNPAID')
    group by 1
    having count(*) >= 20
  )
  select jsonb_build_object(
    'referencia',   (now() at time zone 'America/Sao_Paulo')::date,
    -- Bruto REAL pago pelo cliente nos pedidos ainda não liquidados.
    'total',        coalesce((select round(sum(payment_total),2) from pend), 0),
    'pedidos',      (select count(*) from pend),
    'mais_antigo',  (select min(create_time)::date from pend),
    -- Faixa histórica do repasse (settlement/pago) — contexto, não projeção.
    'repasse_min',  (select round(min(pct),1) from hist),
    'repasse_max',  (select round(max(pct),1) from hist),
    'meses_base',   (select count(*) from hist),
    'atualizado_em',(select max(inserted_at) from tt_pedidos),
    'dias', '[]'::jsonb   -- o TikTok não informa data de liquidação
  );
$function$;

comment on function tt_recebiveis() is
  'Recebíveis TikTok: bruto REAL pago pelo cliente em pedidos ainda não liquidados + faixa histórica de repasse. FORA do total consolidado (decisão do Luciano 17/08/2026): o TikTok não informa data e o repasse varia 73%-101% por causa do subsídio da plataforma.';

revoke all on function tt_recebiveis() from public, anon, authenticated;
grant execute on function tt_recebiveis() to service_role;
