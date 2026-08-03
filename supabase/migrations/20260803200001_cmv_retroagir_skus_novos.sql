-- Retroage os 5 SKUs cadastrados em 20260803190002 (decisão do Luciano, 03/08/2026):
-- eram produtos SEM custo nenhum (não é mudança de preço), então o custo informado
-- vale para TODAS as vendas, inclusive as de julho/2026 que estavam com CMV zero.
-- vigencia_inicio 2026-08-01 -> 2000-01-01 (uma linha só por SKU, aberta).
-- Efeito esperado no DRE: julho/2026 do ML passa a ter CMV para FIRENZE11* (vendas
-- desde 21/07) e ARNIX0*B (desde 29/07). Fev–jun não mudam (primeira venda foi em julho).
-- Rollback: update inverso (vigencia_inicio de volta a '2026-08-01' nesses 5 SKUs).

update public.ml_custo_produto
set vigencia_inicio = '2000-01-01'
where vigencia_inicio = '2026-08-01'
  and sku in ('FIRENZE11MARROM','FIRENZE11BIANCO','FIRENZE11IVORY','ARNIX04PRETOB','ARNIX08PRETOB');
