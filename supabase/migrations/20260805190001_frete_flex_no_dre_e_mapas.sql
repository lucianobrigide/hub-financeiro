-- Frete Flex no DRE + mapas de Seguros/Viagens (decisões Luciano, 05/08/2026).
--
-- 1. FRETE FLEX (ML e Shopee): a entrega própria é paga POR FORA a transportadoras
--    (J3 Flex — R$ 317k desde abr/2024; JG Express antes) em categoria de crédito
--    tributário (2.01.96, excluída). Nenhuma API captura esse custo → estava fora
--    do DRE. Decisão: "nunca pode ficar de fora". Liga-se o forca_inclusao no
--    projeto "Fretes Flex" (→ C2 Fretes Vendas). Auditoria prévia: o projeto é
--    usado SÓ em transportadoras (J3, JG, E-Express) — sem risco de dupla
--    contagem com frete de API (que é o cobrado/creditado PELAS plataformas).
--    Efeito retroativo automático (view): todos os meses, inclusive junho.
--
-- 2. Categorias novas no mapa (projetos batem, linha vem do projeto):
--    2.11.95 Seguros → R5; 2.02.03 Viagens → R19.

UPDATE public.omie_projeto_dre SET forca_inclusao = true WHERE codigo_projeto = '11028072487';  -- Fretes Flex → C2

INSERT INTO public.omie_dre_mapa (codigo_categoria, categoria_nome, dre_code, dre_label, incluir, obs) VALUES
  ('2.11.95', 'Seguros', 'R5',  'Fixo_Seguros',    true, 'Seguros (ex.: Suhai caminhão). Mapeado 05/08/2026 (Luciano); linha via projeto quando houver.'),
  ('2.02.03', 'Viagens', 'R19', 'Eventual_Viagens', true, 'Viagens (ex.: aéreo). Mapeado 05/08/2026 (Luciano); linha via projeto quando houver.')
ON CONFLICT (codigo_categoria) DO UPDATE SET
  categoria_nome = excluded.categoria_nome,
  dre_code = excluded.dre_code,
  dre_label = excluded.dre_label,
  incluir = excluded.incluir,
  obs = excluded.obs;
