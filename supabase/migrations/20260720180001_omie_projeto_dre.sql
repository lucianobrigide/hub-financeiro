-- Classificação primária do DRE = PROJETO (a estrutura do Luciano na Omie espelha as linhas do
-- DRE). A categoria continua sendo o include/exclude e o drill-down.
-- Linha = coalesce(projeto->dre, categoria->dre): projeto manda; sem projeto mapeado, cai na
-- linha da categoria (fallback) — garante que nada é descartado (resultado do DRE preservado).
CREATE TABLE IF NOT EXISTS public.omie_projeto_dre (
  codigo_projeto text PRIMARY KEY,
  dre_code       text NOT NULL,
  nome           text
);
ALTER TABLE public.omie_projeto_dre ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.omie_projeto_dre TO service_role;

INSERT INTO public.omie_projeto_dre (codigo_projeto, dre_code, nome) VALUES
  ('10704277124','R1','Fixo_Folha Salarial'),
  ('10704312539','R2','Fixo_Estrutura Física'),
  ('10704312578','R3','Fixo_Consultoria & Assessoria'),
  ('10704410276','R4','Fixo_Servidores & Softwares'),
  ('10705167001','R5','Fixo_Seguros'),
  ('10760948227','R6','Fixo_Outros'),
  ('10909173402','R7','Fixo_Combustível Adm'),
  ('10710609312','R8','Fixo_Impostos Retidos 3º'),
  ('10705179188','R9','Eventual_Folha Salarial'),
  ('10725942912','R10','Eventual_Estrutura Física'),
  ('10704312597','R11','Eventual_Consultoria & Assessoria'),
  ('10739800013','R12','Eventual_Servidores & Softwares'),
  ('10738171071','R13','Eventual_Cursos & Certificações'),
  ('10972456991','R14','Eventual_Manutenção_Imobilizado'),
  ('11022251675','R14','Fixo_Manutenção Imobilizado'),
  ('10704312524','R15','Eventual_Outros'),
  ('10704346483','R16','Receitas Financeiras'),
  ('10704205493','R17','Despesas Financeiras'),
  ('10741183165','R18','Ativo_Imobilizado'),
  ('11035776360','R19','Eventual_Viagens'),
  ('10704312532','R20','Dividendos'),
  ('10743558033','C1','Marketing & Tráfego'),
  ('10754057198','C2','Frete s/ Vendas'),
  ('11028072487','C2','Fretes Flex'),
  ('11028061378','C3','Fornecedor s/ CP'),
  ('10959649165','C4','Fornecedor Emb.'),
  ('10933275635','C5','Fixo_Combustível'),
  ('10704266416','I1','Impostos s/ Vendas')
ON CONFLICT (codigo_projeto) DO UPDATE
  SET dre_code = EXCLUDED.dre_code, nome = EXCLUDED.nome;
