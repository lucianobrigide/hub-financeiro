-- Correção da régua dos recebíveis Shopee · 17/08/2026
-- A v1 contava como "a receber" TODO pedido sem crédito na carteira — e pedido em
-- devolução nunca recebe crédito, então ficava pendente para sempre, inflando o
-- total em R$ 15.014,21 (11%). Achado na conferência: 122 pedidos com mais de 30
-- dias, incluindo COMPLETED, "esperando" um repasse que não vem.
--
-- Três sinais REAIS da carteira tiram o pedido da conta (nenhum é estimativa):
--   1. order_status = 'TO_RETURN'                         → em devolução
--   2. RETURN_COMPENSATION_SERVICE_ADD no order_sn        → já pago por outro caminho
--   3. ESCROW_VERIFIED_MINUS sem ESCROW_VERIFIED_ADD      → escrow fechado como débito
-- O que sai vira o campo `em_disputa` da resposta — não some sem explicação.
--
-- Efeito medido: R$ 135.608,89 → R$ 120.902,72 a receber (716 pedidos) +
-- R$ 14.706,17 em disputa (151 pedidos). Depois da correção, 98% do valor
-- pendente está em pedidos de até 15 dias — a cauda velha era o erro.

create or replace function shopee_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cobertura as (
    select min(create_time) as desde, max(create_time) as ate from shopee_wallet
  ),
  saldo as (
    select current_balance from shopee_wallet order by create_time desc, transaction_id desc limit 1
  ),
  mov as (
    select order_sn,
           bool_or(transaction_type = 'ESCROW_VERIFIED_ADD')             as teve_credito,
           bool_or(transaction_type = 'ESCROW_VERIFIED_MINUS')           as teve_debito,
           bool_or(transaction_type = 'RETURN_COMPENSATION_SERVICE_ADD') as teve_compensacao
    from shopee_wallet
    where order_sn is not null and order_sn <> ''
    group by order_sn
  ),
  base as (
    select coalesce(p.escrow_adjusted, p.escrow_amount) as valor,
           (p.order_status = 'TO_RETURN'
            or coalesce(m.teve_compensacao, false)
            or coalesce(m.teve_debito, false)) as fora
    from shopee_pedidos p
    left join mov m on m.order_sn = p.order_sn
    cross join cobertura c
    where p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and coalesce(p.escrow_adjusted, p.escrow_amount) is not null
      and p.create_time >= c.desde          -- fora da janela da carteira = desconhecido, não "a receber"
      and coalesce(m.teve_credito, false) = false
  )
  select jsonb_build_object(
    'referencia',    (now() at time zone 'America/Sao_Paulo')::date,
    'total',         coalesce((select round(sum(valor),2) from base where not fora), 0),
    'pedidos',       (select count(*) from base where not fora),
    'em_disputa',    coalesce((select round(sum(valor),2) from base where fora), 0),
    'pedidos_disputa', (select count(*) from base where fora),
    'disponivel',    (select current_balance from saldo),
    'cobertura_de',  (select desde::date from cobertura),
    'cobertura_ate', (select ate::date from cobertura),
    'atualizado_em', (select max(inserted_at) from shopee_wallet),
    'dias', '[]'::jsonb   -- a Shopee não publica data de liberação
  );
$function$;

comment on function shopee_recebiveis() is
  'Recebíveis Shopee: escrow ainda não creditado na carteira, EXCLUINDO devoluções/compensados/escrow fechado como débito (esses vão em em_disputa). Sem cronograma — a API não informa data de liberação.';

revoke all on function shopee_recebiveis() from public, anon, authenticated;
grant execute on function shopee_recebiveis() to service_role;
