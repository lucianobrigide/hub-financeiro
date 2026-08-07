-- Regime de adiantamentos no DRE (decisão Luciano; procedimento executado pela
-- Fernanda — ver ../../PROCEDIMENTO_FERNANDA_ADIANTAMENTOS.md).
--
-- REGRA 1 — adiantamento é despesa: título AP da categoria 2.08.01 COM projeto
-- de linha entra no DRE na linha do projeto, competência = data_entrada (mês do
-- pagamento). Só fonte AP: adiantamentos avulsos da conta corrente (ex.:
-- mercadoria AUSTYN/C7 ARMOR) ficam fora por construção (decisão 06/08).
-- REGRA 2 — NF de baixa é neutra: título com o projeto "Baixa de Adiantamento"
-- (cod 11267806007) NUNCA entra no DRE, independente da categoria — a despesa
-- já contou no adiantamento. Diferenças por retenção (ISS/IR): DRE conta o
-- líquido pago (decisão Luciano 05/08).
-- Backlog jan/2026→hoje marcado pela Fernanda e auditado antes de ligar
-- (créditos ISSQN NF 10 e IPI DUPL sem projeto; NF 11 GDB e IQMAXE NF 18
-- restauradas ao projeto original; ADTO NF 143 com entrada em junho).
--
-- Também: RPC omie_adiantamentos_abertos() — lista "pago aguardando NF" para o
-- fechamento (alerta de adiantamento parado sem baixa).

ALTER TABLE public.omie_projeto_dre ADD COLUMN IF NOT EXISTS excluir_do_dre boolean NOT NULL DEFAULT false;
-- O projeto de baixa não tem linha de DRE por definição
ALTER TABLE public.omie_projeto_dre ALTER COLUMN dre_code DROP NOT NULL;
COMMENT ON COLUMN public.omie_projeto_dre.excluir_do_dre IS
  'true = lançamentos deste projeto NUNCA entram no DRE (uso: projeto "Baixa de Adiantamento" — a NF que baixa um adiantamento é neutra; a despesa já contou no adiantamento).';

INSERT INTO public.omie_projeto_dre (codigo_projeto, nome, dre_code, forca_inclusao, excluir_do_dre)
VALUES ('11267806007', 'Baixa de Adiantamento', NULL, false, true)
ON CONFLICT (codigo_projeto) DO UPDATE SET nome = excluded.nome, excluir_do_dre = true;

-- Rótulo legível no drill-down (2.08.01 continua incluir=false; a inclusão é
-- pela regra nova, restrita a AP + projeto de linha)
UPDATE public.omie_dre_mapa
   SET categoria_nome = 'Adiantamento a Fornecedores (sem NF)',
       obs = 'Adiantamento: ATIVO por padrão (fora do DRE). EXCEÇÃO (06/08/2026): título AP com projeto de linha = despesa paga aguardando NF — entra na linha do projeto no mês do pagamento; a NF posterior vem com o projeto "Baixa de Adiantamento" e é neutra.'
 WHERE codigo_categoria = '2.08.01';

CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_object_agg(dre_code, valor), '{}'::jsonb)
  FROM (
    SELECT COALESCE(pj.dre_code, m.dre_code) AS dre_code, round(sum(l.valor), 2) AS valor
    FROM public.omie_dre_lancamentos l
    LEFT JOIN public.omie_dre_mapa m ON m.codigo_categoria = l.codigo_categoria
    LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
    WHERE l.valido AND to_char(l.competencia_data, 'YYYY-MM') = p_month
      AND NOT coalesce(pj.excluir_do_dre, false)
      AND ( (m.incluir AND m.dre_code IS NOT NULL)
         OR (pj.forca_inclusao AND pj.dre_code IS NOT NULL)
         OR (l.fonte = 'AP' AND l.codigo_categoria = '2.08.01' AND pj.dre_code IS NOT NULL) )
    GROUP BY COALESCE(pj.dre_code, m.dre_code)
  ) s;
$function$;

CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r_detalhe(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dre_code', dre_code, 'nome', nome, 'valor', valor)
                            ORDER BY dre_code, valor DESC), '[]'::jsonb)
  FROM (
    SELECT COALESCE(pj.dre_code, m.dre_code) AS dre_code,
           COALESCE(m.categoria_nome, m.codigo_categoria, l.codigo_categoria) AS nome,
           round(sum(l.valor), 2) AS valor
    FROM public.omie_dre_lancamentos l
    LEFT JOIN public.omie_dre_mapa m ON m.codigo_categoria = l.codigo_categoria
    LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
    WHERE l.valido AND to_char(l.competencia_data, 'YYYY-MM') = p_month
      AND NOT coalesce(pj.excluir_do_dre, false)
      AND ( (m.incluir AND m.dre_code IS NOT NULL)
         OR (pj.forca_inclusao AND pj.dre_code IS NOT NULL)
         OR (l.fonte = 'AP' AND l.codigo_categoria = '2.08.01' AND pj.dre_code IS NOT NULL) )
    GROUP BY COALESCE(pj.dre_code, m.dre_code), COALESCE(m.categoria_nome, m.codigo_categoria, l.codigo_categoria)
    HAVING round(sum(l.valor), 2) <> 0
  ) s;
$function$;

CREATE OR REPLACE FUNCTION public.omie_dre_itens(p_month text, p_dre_code text, p_categoria text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fornecedor', COALESCE(nullif(f.razao_social,''), l.fornecedor_cod::text),
    'valor', round(l.valor, 2),
    'data', to_char(l.competencia_data, 'DD/MM'),
    'doc', l.doc,
    'fonte', l.fonte) ORDER BY l.valor DESC), '[]'::jsonb)
  FROM public.omie_dre_lancamentos l
  LEFT JOIN public.omie_dre_mapa m ON m.codigo_categoria = l.codigo_categoria
  LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
  LEFT JOIN public.omie_fornecedores f ON f.codigo_cliente = l.fornecedor_cod
  WHERE l.valido AND to_char(l.competencia_data, 'YYYY-MM') = p_month
    AND NOT coalesce(pj.excluir_do_dre, false)
    AND ( (m.incluir AND m.dre_code IS NOT NULL)
       OR (pj.forca_inclusao AND pj.dre_code IS NOT NULL)
       OR (l.fonte = 'AP' AND l.codigo_categoria = '2.08.01' AND pj.dre_code IS NOT NULL) )
    AND COALESCE(pj.dre_code, m.dre_code) = p_dre_code
    AND COALESCE(m.categoria_nome, m.codigo_categoria, l.codigo_categoria) = p_categoria;
$function$;

-- Alerta de fechamento: adiantamentos pagos aguardando NF (com projeto de linha)
CREATE OR REPLACE FUNCTION public.omie_adiantamentos_abertos()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fornecedor', COALESCE(nullif(f.razao_social,''), l.fornecedor_cod::text),
    'doc', l.doc, 'valor', round(l.valor,2), 'linha', pj.dre_code,
    'competencia', to_char(l.competencia_data,'DD/MM/YYYY'),
    'dias_aberto', (current_date - l.competencia_data)
  ) ORDER BY l.competencia_data), '[]'::jsonb)
  FROM public.omie_dre_lancamentos l
  JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
    AND pj.dre_code IS NOT NULL AND NOT pj.excluir_do_dre AND NOT pj.forca_inclusao
  LEFT JOIN public.omie_fornecedores f ON f.codigo_cliente = l.fornecedor_cod
  WHERE l.valido AND l.fonte = 'AP' AND l.codigo_categoria = '2.08.01'
    AND l.competencia_data <= current_date;
$function$;
