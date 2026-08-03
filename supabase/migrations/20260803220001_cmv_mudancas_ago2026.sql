-- Mudanças de custo a partir de 01/08/2026, passadas pelo Luciano via planilha
-- CMV_custos_agosto_2026.xlsx (03/08/2026). Fluxo oficial cmv_alterar_custo():
-- fecha a linha vigente (vigencia_fim = 2026-08-01) e insere a nova — o valor
-- antigo continua valendo para toda venda até 31/07 (junho/julho não mudam).
--   FIRENZE10BIANCO  149,00415 -> 140,00      FIRENZE10IVORY   153,999 -> 145,00
--   FIRENZE10CAPPU   149,00415 -> 140,00      FIRENZE10MARROMD 153,999 -> 145,00
--   MARPALCACAP      126,5007  -> 135,00      FIRENZE10ROSAD   153,999 -> 145,00
-- (MARPALCACAR ficou em branco na planilha = manteve 126,5007.)
-- Rollback por SKU: delete da linha com vigencia_inicio='2026-08-01' + update da
-- linha anterior com vigencia_fim=null.

select public.cmv_alterar_custo('FIRENZE10BIANCO',  140.00, '2026-08-01');
select public.cmv_alterar_custo('FIRENZE10CAPPU',   140.00, '2026-08-01');
select public.cmv_alterar_custo('FIRENZE10IVORY',   145.00, '2026-08-01');
select public.cmv_alterar_custo('FIRENZE10MARROMD', 145.00, '2026-08-01');
select public.cmv_alterar_custo('FIRENZE10ROSAD',   145.00, '2026-08-01');
select public.cmv_alterar_custo('MARPALCACAP',      135.00, '2026-08-01');
