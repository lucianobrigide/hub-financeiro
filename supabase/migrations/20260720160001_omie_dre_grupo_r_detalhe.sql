-- Drill-down do DRE: nome legível de cada categoria + RPC que devolve as subcategorias por linha.
ALTER TABLE public.omie_dre_mapa ADD COLUMN IF NOT EXISTS categoria_nome text;

UPDATE public.omie_dre_mapa m SET categoria_nome = v.nome
FROM (VALUES
  ('2.02.02','Marketing'),('2.02.98','Conteúdos p/ Redes Sociais'),('2.02.99','Frete s/ Vendas'),
  ('2.01.99','Material de Embalagem'),('2.11.99','Combustível'),
  ('2.03.96','Pró-labore'),('2.03.06','INSS'),('2.03.10','Assistência Médica'),
  ('2.03.11','Vale Transporte'),('2.03.12','Vale Refeição'),('2.03.95','Bolsa Auxílio Estágio'),
  ('2.03.98','Contribuição Sindical'),
  ('2.04.01','Aluguel'),('2.04.03','Água e Esgoto'),('2.04.04','Energia Elétrica'),
  ('2.04.09','IPTU'),('2.04.14','Limpeza'),('2.10.94','Monitoramento Patrimonial'),
  ('2.10.95','Telefonia e Redes'),
  ('2.10.93','Outros Serviços Tomados (mão de obra)'),('2.10.98','Jurídico'),('2.10.99','Contábil'),
  ('2.10.92','SaaS'),('2.04.08','Seguros'),
  ('2.07.98','Bens de pequeno valor'),('2.04.12','Confraternização'),('2.04.99','Copa e Cozinha'),
  ('2.04.06','Material de Escritório'),('2.06.95','Taxas Diversas'),('2.01.97','Material EPIs'),
  ('2.01.98','Material de Uso/Consumo'),
  ('2.06.93','ISSQN Retido 3º'),('2.03.97','Instrução e Treinamentos'),
  ('2.04.07','Manutenção de Imobilizado'),('2.11.97','Revisão de veículos'),
  ('2.10.97','Serviços Financeiros'),
  ('2.07.05','Móveis e Utensílios'),('2.07.02','Veículos'),('2.07.04','Equip. de Informática'),
  ('2.03.99','Dividendos Antecipados')
) AS v(cod, nome)
WHERE m.codigo_categoria = v.cod;

-- Detalhe: subcategorias (com valor) de cada linha do DRE, no mês. Ordena por linha e valor desc.
CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r_detalhe(p_month text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dre_code', dre_code, 'nome', nome, 'valor', valor)
                            ORDER BY dre_code, valor DESC), '[]'::jsonb)
  FROM (
    SELECT m.dre_code, COALESCE(m.categoria_nome, m.codigo_categoria) AS nome, round(sum(d.valor), 2) AS valor
    FROM public.omie_despesas d
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = d.codigo_categoria
    WHERE m.incluir AND m.dre_code IS NOT NULL
      AND d.status_titulo <> 'CANCELADO'
      AND to_char(d.data_emissao, 'YYYY-MM') = p_month
    GROUP BY m.dre_code, COALESCE(m.categoria_nome, m.codigo_categoria)
    HAVING round(sum(d.valor), 2) <> 0
  ) s;
$function$;

REVOKE ALL ON FUNCTION public.omie_dre_grupo_r_detalhe(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.omie_dre_grupo_r_detalhe(text) TO service_role;
