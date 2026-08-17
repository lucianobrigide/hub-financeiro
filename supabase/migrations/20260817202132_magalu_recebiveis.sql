-- ============================================================================
-- Magalu — recebíveis (F.C. Projetado) · 17/08/2026
-- ============================================================================
-- ⚠️ SEM cronograma: o Magalu não publica data de repasse. A API de **Análise
-- Financeira** (`GET /seller/v1/financial-analysis/orders`, escopo
-- `open:order-financial-report-seller:read`, JÁ autorizado — janela máx. 15 dias
-- por `purchased_at__gte/lte`, ou `order_id` avulso, que aceita só o CODE
-- numérico, não o UUID) é uma visão CONTÁBIL por pedido (CREDIT/DEBIT/
-- INFORMATIVE, comissão, MDR, subsídios) e **não tem campo de data de
-- pagamento** — só created_at/updated_at. Verificado na doc e na API em
-- 17/08/2026.
--
-- ⚠️ E hoje ela vem VAZIA: só devolve pedidos "Entregue"/"Cancelado faturado"
-- (e só a partir de 05/05/2026), e a operação Magalu tem 2 pedidos — 1 cancelado
-- em 30/07 e 1 criado em 17/08. Testado por janela de datas e por order_id:
-- HTTP 200, count = 0 em todos.
--
-- Régua (MVP, coerente com o card do canal): a receber = Σ (valor_total −
-- comissão − frete) dos pedidos não cancelados. Comissão e frete são REAIS,
-- vêm do próprio pedido (/seller/v1/orders). Não há sinal de "já repassado"
-- em lugar nenhum da API, então nada é abatido — o que é correto HOJE, com a
-- operação recém-aberta e nenhum repasse ocorrido.
--
-- ⚠️ PENDÊNCIA: quando o PRIMEIRO repasse do Magalu cair, descobrir onde a API
-- registra isso e passar a abater — senão o total vira acumulado eterno.
--
-- Sem cron próprio: o magalu-diario já mantém magalu_pedidos.

create or replace function magalu_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with base as (
    select code,
           coalesce(valor_total,0) - coalesce(comissao,0) - coalesce(frete,0) as liquido,
           created_at
    from magalu_pedidos
    where status <> 'cancelled'
  )
  select jsonb_build_object(
    'referencia',   (now() at time zone 'America/Sao_Paulo')::date,
    'total',        coalesce((select round(sum(liquido),2) from base), 0),
    'pedidos',      (select count(*) from base),
    'mais_antigo',  (select min(created_at)::date from base),
    'atualizado_em',(select max(updated_at) from magalu_pedidos),
    'dias', '[]'::jsonb   -- o Magalu não publica data de repasse
  );
$function$;

comment on function magalu_recebiveis() is
  'Recebíveis Magalu (MVP): líquido real dos pedidos não cancelados (total − comissão − frete). SEM cronograma — o Magalu não publica data de repasse, e a API de Análise Financeira (autorizada) ainda vem vazia. PENDÊNCIA: abater o que já foi repassado quando o 1º repasse cair.';

revoke all on function magalu_recebiveis() from public, anon, authenticated;
grant execute on function magalu_recebiveis() to service_role;
