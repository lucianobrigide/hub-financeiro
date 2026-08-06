-- omie_dre_mapa: 5 categorias que apareceram pela 1ª vez em julho/2026
-- (conferência do DRE com o Luciano, 05/08/2026).
--
-- Os lançamentos já vinham da Omie com projeto e categoria corretos (Fernanda),
-- mas o grupo_r exige a categoria cadastrada no mapa (incluir=true) mesmo quando
-- o projeto resolve a linha — categoria fora do mapa some do DRE em silêncio.
-- O dre_code aqui é o FALLBACK (vale só se um lançamento futuro vier sem
-- projeto); com projeto preenchido, vale o omie_projeto_dre, como sempre.
--
-- De-para confirmado pelo Luciano:
--   2.05.02 Multas (multas de trânsito)      → projeto Eventual_Outros (R15)
--   2.04.96 Aluguel de Equipamento (Atlasmotus) → projeto Fixo_Estrutura Física (R2)
--   2.04.98 Refeições (reembolso Luciano)    → projeto Eventual_Outros (R15)
--   2.04.05 Material de Uso/Consumo (Laminação) → projeto Eventual_Outros (R15)
--   2.04.11 Postais (correio de devolução)   → projeto Eventual_Outros (R15)

INSERT INTO public.omie_dre_mapa (codigo_categoria, categoria_nome, dre_code, dre_label, incluir, obs) VALUES
  ('2.05.02', 'Multas',                  'R15', 'Eventual_Outros',        true, 'Multas de trânsito. Mapeado 05/08/2026 (Luciano); linha via projeto Eventual_Outros.'),
  ('2.04.96', 'Aluguel de Equipamento',  'R2',  'Fixo_Estrutura Física',  true, 'Locação de empilhadeira (Atlasmotus). Mapeado 05/08/2026 (Luciano); linha via projeto Fixo_Estrutura Física.'),
  ('2.04.98', 'Refeições',               'R15', 'Eventual_Outros',        true, 'Refeições/reembolsos. Mapeado 05/08/2026 (Luciano); linha via projeto Eventual_Outros.'),
  ('2.04.05', 'Material de Uso/Consumo', 'R15', 'Eventual_Outros',        true, 'Material de consumo. Mapeado 05/08/2026 (Luciano); linha via projeto Eventual_Outros.'),
  ('2.04.11', 'Postais',                 'R15', 'Eventual_Outros',        true, 'Correios (ex.: postagem de devolução paga por fora). Mapeado 05/08/2026 (Luciano); linha via projeto Eventual_Outros.')
ON CONFLICT (codigo_categoria) DO UPDATE SET
  categoria_nome = excluded.categoria_nome,
  dre_code = excluded.dre_code,
  dre_label = excluded.dre_label,
  incluir = excluded.incluir,
  obs = excluded.obs;
