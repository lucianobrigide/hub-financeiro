-- Categorias que estavam FORA do mapa (e portanto sendo silenciosamente descartadas do DRE,
-- pois os RPCs fazem JOIN com o mapa). Achadas na análise de Junho:
--  * 2.04.13 Segurança (ex.: União Master Paper) — despesa real -> R2 (linha vem do projeto quando houver)
--  * 2.05.04 Tarifas Bancárias -> R17 Despesas Financeiras
--  * 2.05.99 IOF (encargo financeiro) -> R17
--  * 0.01.02 Saída de Transferência -> transferência entre contas próprias, NÃO é despesa (fora)
INSERT INTO public.omie_dre_mapa (codigo_categoria, dre_code, dre_label, incluir, categoria_nome, obs) VALUES
  ('2.04.13','R2','Fixo_Estrutura Física',true,'Segurança','Segurança (ex.: União Master Paper). Linha vem do projeto quando houver.'),
  ('2.05.04','R17','Despesas Financeiras',true,'Tarifas Bancárias','Tarifas bancárias — despesa financeira'),
  ('2.05.99','R17','Despesas Financeiras',true,'IOF','IOF (encargo sobre operações financeiras) — em Despesas Financeiras'),
  ('0.01.02',null,'Transferência',false,'Saída de Transferência','Transferência entre contas próprias — NÃO é despesa, fora do DRE')
ON CONFLICT (codigo_categoria) DO UPDATE
  SET dre_code=EXCLUDED.dre_code, dre_label=EXCLUDED.dre_label, incluir=EXCLUDED.incluir,
      categoria_nome=EXCLUDED.categoria_nome, obs=EXCLUDED.obs;
