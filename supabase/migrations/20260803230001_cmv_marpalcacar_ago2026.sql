-- Complemento da planilha de agosto (Luciano, 03/08/2026): MARPALCACAR também
-- mudou — 126,5007 -> 135,00 a partir de 01/08 (igual ao MARPALCACAP, mesmo
-- modelo MARPALCACA; tinha ficado em branco na planilha por engano).
-- Rollback: delete da linha (MARPALCACAR, 2026-08-01) + reabrir a anterior (vigencia_fim=null).

select public.cmv_alterar_custo('MARPALCACAR', 135.00, '2026-08-01');
