-- SKUs órfãos com custo passado pelo Luciano (03/08/2026), vigência a partir de 01/08/2026.
-- FIRENZE11 (3 variantes ML) = R$ 274,00 · ARNIX04PRETOB = R$ 65,40 · ARNIX08PRETOB = R$ 96,50.
-- Vigência 2026-08-01 DE PROPÓSITO: vendas de julho desses SKUs continuam sem CMV
-- (regra "junho e julho não mudam nem um centavo"). Para retroagir, inserir outra
-- linha do mesmo SKU com daterange anterior, ex.: [2000-01-01, 2026-08-01).
-- Ficam SEM custo (aguardando valor): MARPAL9PRETO_A, MARPAL9ROSE_A, MARPAL9PRETOB_A (Amazon), 3FRIG_MARROM (TikTok).
-- Rollback: delete from ml_custo_produto where vigencia_inicio = '2026-08-01';

insert into public.ml_custo_produto (sku, modelo, custo, origem, vigencia_inicio) values
  ('FIRENZE11MARROM', 'FIRENZE11', 274.00, 'confirmado', '2026-08-01'),
  ('FIRENZE11BIANCO', 'FIRENZE11', 274.00, 'confirmado', '2026-08-01'),
  ('FIRENZE11IVORY',  'FIRENZE11', 274.00, 'confirmado', '2026-08-01'),
  ('ARNIX04PRETOB',   'ARNIX04',    65.40, 'confirmado', '2026-08-01'),
  ('ARNIX08PRETOB',   'ARNIX08',    96.50, 'confirmado', '2026-08-01');
