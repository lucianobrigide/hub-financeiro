-- omie_adiantamentos_abertos v2: só os realmente pendentes de NF.
-- A v1 listava todo adiantamento-despesa (44 itens), mesmo os que já têm NF de
-- baixa — alerta inútil. Heurística: adiantamento é considerado BAIXADO quando
-- existe título do MESMO fornecedor com o projeto "Baixa de Adiantamento" e
-- competência igual ou posterior à do adiantamento.

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
    AND l.competencia_data <= current_date
    AND NOT EXISTS (
      SELECT 1
      FROM public.omie_dre_lancamentos b
      JOIN public.omie_projeto_dre bpj ON bpj.codigo_projeto = b.codigo_projeto AND bpj.excluir_do_dre
      WHERE b.valido AND b.fornecedor_cod = l.fornecedor_cod
        AND b.competencia_data >= l.competencia_data
    );
$function$;
