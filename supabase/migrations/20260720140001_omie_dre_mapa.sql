-- ETAPA 1 do projeto DRE: de-para categoria Omie -> linha do DRE Essenza (código R#/C#/I#).
-- incluir=false: categoria que NÃO entra no DRE (dupla contagem c/ o Hub, ou balanço/ativo).
-- Estado travado com o Luciano (Jul/2026). Decisões-chave:
--   * Folha (R1) fica BAIXA de propósito: não há CLT, só pró-labore/encargos.
--   * Mão de obra é 100% terceirizada -> entra como "Outros Serviços Tomados" em R3.
--   * "Serviços Essenciais" = custo de plataforma já capturado no Hub -> fora (incluir=false).
--   * Compras/CMV, Taxas E-commerce, DIFAL, IPI, Adiantamentos -> fora (Hub/balanço).
CREATE TABLE IF NOT EXISTS public.omie_dre_mapa (
  codigo_categoria text PRIMARY KEY,
  dre_code   text,
  dre_label  text,
  incluir    boolean NOT NULL DEFAULT true,
  obs        text
);
ALTER TABLE public.omie_dre_mapa ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.omie_dre_mapa TO service_role;

INSERT INTO public.omie_dre_mapa (codigo_categoria, dre_code, dre_label, incluir, obs) VALUES
  -- Acima da MC (fonte Omie, não vem do Hub)
  ('2.02.02','C1','Marketing & Tráfego',true,'Marketing próprio (off-marketplace)'),
  ('2.02.98','C1','Marketing & Tráfego',true,'Conteúdos p/ Redes Sociais'),
  ('2.02.99','C2','Fretes Vendas',true,'REVISAR: overlap c/ frete marketplace já capturado no Hub'),
  ('2.01.99','C4','Fornecedor Emb.',true,'Material de Embalagem'),
  ('2.11.99','C5','Fixo_Combustível',true,'REVISAR: split C5 operacional vs R7 adm por departamento'),
  -- R1 Folha (baixa de propósito — sem CLT)
  ('2.03.96','R1','Fixo_Folha Salarial',true,'Pró-labore'),
  ('2.03.06','R1','Fixo_Folha Salarial',true,'INSS'),
  ('2.03.10','R1','Fixo_Folha Salarial',true,'Assistência Médica'),
  ('2.03.11','R1','Fixo_Folha Salarial',true,'Vale Transporte'),
  ('2.03.12','R1','Fixo_Folha Salarial',true,'Vale Refeição'),
  ('2.03.95','R1','Fixo_Folha Salarial',true,'Bolsa Auxílio Estágio'),
  ('2.03.98','R1','Fixo_Folha Salarial',true,'Contribuição Sindical'),
  -- R2 Estrutura Física
  ('2.04.01','R2','Fixo_Estrutura Física',true,'Aluguel'),
  ('2.04.03','R2','Fixo_Estrutura Física',true,'Água e Esgoto'),
  ('2.04.04','R2','Fixo_Estrutura Física',true,'Energia Elétrica'),
  ('2.04.09','R2','Fixo_Estrutura Física',true,'IPTU'),
  ('2.04.14','R2','Fixo_Estrutura Física',true,'Limpeza'),
  ('2.10.94','R2','Fixo_Estrutura Física',true,'Monitoramento Patrimonial'),
  ('2.10.95','R2','Fixo_Estrutura Física',true,'Telefonia e Redes'),
  -- R3 Consultoria & Assessoria (inclui mão de obra terceirizada)
  ('2.10.93','R3','Fixo_Consultoria & Assessoria',true,'Outros Serviços Tomados — inclui mão de obra terceirizada (a folha real da empresa; R1 fica baixa de propósito)'),
  ('2.10.98','R3','Fixo_Consultoria & Assessoria',true,'Jurídico'),
  ('2.10.99','R3','Fixo_Consultoria & Assessoria',true,'Contábil'),
  -- R4 Servidores & Softwares
  ('2.10.92','R4','Fixo_Servidores & Softwares',true,'SaaS'),
  -- R5 Seguros
  ('2.04.08','R5','Fixo_Seguros',true,'Seguros'),
  -- R6 Outros
  ('2.07.98','R6','Fixo_Outros',true,'Bens de pequeno valor'),
  ('2.04.12','R6','Fixo_Outros',true,'Confraternização'),
  ('2.04.99','R6','Fixo_Outros',true,'Copa e Cozinha'),
  ('2.04.06','R6','Fixo_Outros',true,'Material de Escritório'),
  ('2.06.95','R6','Fixo_Outros',true,'Taxas Diversas'),
  ('2.01.97','R6','Fixo_Outros',true,'Material EPIs'),
  ('2.01.98','R6','Fixo_Outros',true,'Material de Uso/Consumo (o pico de 115k em jun era a NF 3908 Arnix mal classificada — corrigida na Omie p/ 2.01.01)'),
  -- R8 Impostos Retidos 3º
  ('2.06.93','R8','Fixo_Impostos Retidos 3º',true,'ISSQN Retido 3º'),
  -- R13 Cursos & Certificações
  ('2.03.97','R13','Eventual_Cursos & Certificações',true,'Instrução e Treinamentos'),
  -- R14 Manutenção Imobilizado
  ('2.04.07','R14','Eventual_Manutenção_Imobilizado',true,'Manutenção de Imobilizado'),
  ('2.11.97','R14','Eventual_Manutenção_Imobilizado',true,'Revisão de veículos'),
  -- R17 Despesas Financeiras
  ('2.10.97','R17','Despesas Financeiras',true,'Serviços Financeiros (tarifas/juros)'),
  -- R18 Ativo Imobilizado (CAPEX)
  ('2.07.05','R18','Ativo_Imobilizado',true,'Móveis e Utensílios'),
  ('2.07.02','R18','Ativo_Imobilizado',true,'Veículos'),
  ('2.07.04','R18','Ativo_Imobilizado',true,'Equipamentos de Informática'),
  -- R20 Dividendos
  ('2.03.99','R20','Dividendos',true,'Omie classifica sob Pessoal, mas é distribuição de lucro'),
  -- EXCLUÍDOS: Hub já captura (dupla contagem) ou balanço
  ('2.06.94','I1','DIFAL',false,'REVISAR: Hub capta DIFAL de vendas (ML+Shopee); ver se Omie tem DIFAL de compras à parte'),
  ('2.06.02','I2','IPI',false,'REVISAR: IPI já embutido no faturamento B2B'),
  ('2.01.01',NULL,'CMV (Hub)',false,'Compras p/ Revenda = CMV, vem do Hub'),
  ('2.01.96',NULL,'Plataforma (Hub)',false,'Serviços Essenciais = custo de plataforma, já capturado no Hub por outra via'),
  ('2.02.97',NULL,'Comissão (Hub)',false,'Taxas E-commerce = comissão marketplace, vem do Hub'),
  ('2.08.01',NULL,'Balanço',false,'Adiantamento a Fornecedores — ativo, não é resultado')
ON CONFLICT (codigo_categoria) DO UPDATE
  SET dre_code=EXCLUDED.dre_code, dre_label=EXCLUDED.dre_label, incluir=EXCLUDED.incluir, obs=EXCLUDED.obs;