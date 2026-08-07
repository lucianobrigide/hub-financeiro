-- Projeto "Baixa de Adiantamento" DUPLICADO na Omie (cod. 11267745944).
--
-- Detectado pelo Luciano em 07/08: a NF 0000000014 da GDB (R$ 98.470) voltou a
-- contar no R3 de junho, dobrando com o ADTO NF 14 (R$ 100.000). Causa: a NF
-- estava com um SEGUNDO projeto de mesmo nome "Baixa de Adiantamento"
-- (cod. 11267745944) que o Hub não conhecia — só o 11267806007 estava
-- cadastrado com excluir_do_dre. Único lançamento com o duplicado até agora.
-- Cadastra o duplicado com a mesma função (excluir do DRE). Recomendação à
-- Fernanda: apagar o projeto duplicado na Omie e usar sempre o original.

INSERT INTO public.omie_projeto_dre (codigo_projeto, nome, dre_code, forca_inclusao, excluir_do_dre)
VALUES ('11267745944', 'Baixa de Adiantamento (duplicado)', NULL, false, true)
ON CONFLICT (codigo_projeto) DO UPDATE SET nome = excluded.nome, dre_code = NULL, forca_inclusao = false, excluir_do_dre = true;
