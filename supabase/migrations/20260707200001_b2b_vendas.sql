-- B2B / Vendas Internas: notas fiscais do TINY filtradas por natureza de operação.
-- Fonte de dados: API v3 TINY GET /notas/{id}. Competência por data de emissão.
-- Bruta = valor_total (com IPI). CMV cruza b2b_itens × ml_custo_produto.
-- Nenhum segredo neste arquivo.

CREATE TABLE IF NOT EXISTS public.b2b_notas (
  id             bigint PRIMARY KEY,
  numero         text NOT NULL,
  serie          text NOT NULL,
  data_emissao   date NOT NULL,
  valor_produtos numeric NOT NULL,
  valor_total    numeric NOT NULL,
  situacao       smallint NOT NULL,
  cliente_nome   text,
  cliente_cnpj   text,
  natureza       text,
  UNIQUE(numero, serie)
);
ALTER TABLE public.b2b_notas ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.b2b_itens (
  id             bigint PRIMARY KEY,
  nota_id        bigint NOT NULL REFERENCES public.b2b_notas(id),
  sku            text NOT NULL,
  descricao      text,
  quantidade     numeric NOT NULL,
  valor_unitario numeric NOT NULL,
  valor_total    numeric NOT NULL,
  cfop           text,
  natureza       text
);
ALTER TABLE public.b2b_itens ENABLE ROW LEVEL SECURITY;

-- Seed: 3 NFs de junho/2026 (B2B completo do mês, confirmado)
INSERT INTO public.b2b_notas (id, numero, serie, data_emissao, valor_produtos, valor_total, situacao, cliente_nome, cliente_cnpj, natureza) VALUES
  (402981087, '000015', '15', '2026-06-02', 12.48, 12.48, 7, 'AMANDA QUEIROZ', '426.798.798-05', 'Venda de mercadorias (Para Colaborador da Empresa)'),
  (403102420, '000016', '15', '2026-06-03', 51.42, 51.42, 7, 'Nailze Aparecida Ribeiro Silva', '127.008.818-18', 'Venda de mercadorias (Para Colaborador da Empresa)'),
  (403144529, '004102', '7',  '2026-06-03', 43192.00, 45999.48, 7, 'JIREH COMERCIO DIGITAL LTDA', '63.489.643/0001-60', 'Venda de Mercadorias Importadas para Contribuinte -B2B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.b2b_itens (id, nota_id, sku, descricao, quantidade, valor_unitario, valor_total, cfop, natureza) VALUES
  (749623112, 402981087, 'RTP3', 'Rolo Adesivo Tira Pelos Roupas Sofá + 2 Refis', 2, 6.24, 12.48, '5102', 'Venda de mercadorias (Para Colaborador da Empresa)'),
  (749642606, 403102420, 'JARRAD14', 'Jarra de Vidro 1,4L Resistente Com Tampa Suco Água ou Chá', 3, 17.14, 51.42, '5102', 'Venda de mercadorias (Para Colaborador da Empresa)'),
  (749648074, 403144529, 'ESSENZA10BIANCO', 'Jogo De Panelas 10 Peças Bianco Antiaderente Essenza Di Chef - Bianco', 400, 107.98, 43192.00, '5102', 'Venda de Mercadorias Importadas para Contribuinte -B2B')
ON CONFLICT (id) DO NOTHING;

-- Faturamento bruto B2B (competência por data_emissao, valor_total = com IPI)
CREATE OR REPLACE FUNCTION public.b2b_faturamento(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'faturamento_bruto', coalesce(sum(valor_total), 0),
    'total_notas', count(*)
  )
  FROM b2b_notas
  WHERE to_char(data_emissao, 'YYYY-MM') = p_month
    AND situacao IN (6, 7);
$$;

-- CMV B2B: cruza b2b_itens × ml_custo_produto
CREATE OR REPLACE FUNCTION public.b2b_cmv(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'cmv_total', coalesce(sum(i.quantidade * c.custo), 0),
    'itens_com_custo', count(c.sku),
    'itens_total', count(i.sku)
  )
  FROM b2b_itens i
  JOIN b2b_notas n ON n.id = i.nota_id
  LEFT JOIN ml_custo_produto c ON c.sku = i.sku
  WHERE to_char(n.data_emissao, 'YYYY-MM') = p_month
    AND n.situacao IN (6, 7);
$$;

REVOKE ALL ON FUNCTION public.b2b_faturamento(text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.b2b_cmv(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.b2b_faturamento(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.b2b_cmv(text) TO service_role;
