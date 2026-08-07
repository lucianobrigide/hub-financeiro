-- Projeto "Tráfego Pago" (cod. Omie 11267209201) → C1 com força de inclusão.
--
-- A Fernanda criou um projeto dedicado para tráfego pago e o aplicou na série
-- IQMAXE e na NF Bytedance 3605955 (R$ 301,43, TikTok Ads jun/2026, categoria
-- 2.01.96 mantida pelo crédito tributário). É o discriminador limpo que faltava
-- para tráfego pago dentro de categoria excluída (a solução "opção b" da
-- conversa de 05-06/08). Auditoria prévia dos 16 lançamentos do projeto:
-- 14× IQMAXE (2.02.02, já entram por categoria), 1× Bytedance (2.01.96 → passa
-- a entrar via força), e 2 caronas sinalizadas ao Luciano (gás Chama's R$ 335,
-- que muda de R18 p/ C1 pelo override; ISSQN NF 17 R$ 20, adiantamento-crédito
-- que passa a entrar) — ajustes de marcação na Omie, se necessários.

INSERT INTO public.omie_projeto_dre (codigo_projeto, nome, dre_code, forca_inclusao, excluir_do_dre)
VALUES ('11267209201', 'Tráfego Pago', 'C1', true, false)
ON CONFLICT (codigo_projeto) DO UPDATE SET nome = excluded.nome, dre_code = 'C1', forca_inclusao = true, excluir_do_dre = false;
