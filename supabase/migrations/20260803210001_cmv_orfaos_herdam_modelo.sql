-- Últimos 4 SKUs órfãos, custo herdado do modelo (decisão do Luciano, 03/08/2026):
--   MARPAL9PRETO_A / MARPAL9PRETOB_A / MARPAL9ROSE_A (variantes _A vendidas na Amazon)
--     -> mesmo custo das MARPAL9 já cadastradas: R$ 127,59765
--   3FRIG_MARROM (TikTok) -> custo do kit 3 frigideiras (modelo 3FRIG): R$ 49,00065
-- Retroativos (vigência 2000-01-01), mesma regra da 20260803200001: SKU sem custo
-- não é mudança de preço — vale para todas as vendas (as de julho/2026 incluídas).
-- Com isso a cobertura de CMV dos últimos 6 meses fecha em 100% dos SKUs vendidos.
-- Rollback: delete from ml_custo_produto where sku in (...4 skus...);

insert into public.ml_custo_produto (sku, modelo, custo, origem, vigencia_inicio) values
  ('MARPAL9PRETO_A',  'MARPAL9', 127.59765, 'confirmado', '2000-01-01'),
  ('MARPAL9PRETOB_A', 'MARPAL9', 127.59765, 'confirmado', '2000-01-01'),
  ('MARPAL9ROSE_A',   'MARPAL9', 127.59765, 'confirmado', '2000-01-01'),
  ('3FRIG_MARROM',    '3FRIG',    49.00065, 'confirmado', '2000-01-01');
