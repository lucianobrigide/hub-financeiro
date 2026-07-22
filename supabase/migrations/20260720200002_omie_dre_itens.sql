-- View ganha fornecedor/doc/fonte (colunas ao final) p/ o 3º nível de drill-down (item unitário).
CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
  SELECT codigo_categoria,
         raw->>'codigo_projeto' AS codigo_projeto,
         valor,
         COALESCE(data_emissao, data_vencimento) AS competencia_data,
         (status_titulo <> 'CANCELADO') AS valido,
         codigo_cliente_fornecedor AS fornecedor_cod,
         raw->>'numero_documento' AS doc,
         'AP'::text AS fonte
  FROM public.omie_despesas
  UNION ALL
  SELECT codigo_categoria, codigo_projeto, valor,
         data_pagamento, (c_status <> 'CANCELADO'),
         n_cod_cliente, raw->'detalhes'->>'cNumTitulo', 'CC'::text
  FROM public.omie_mov_cc mc
  WHERE COALESCE(mc.n_cod_titulo, 0) = 0
    AND NOT EXISTS (SELECT 1 FROM public.omie_forn_plataforma p WHERE p.codigo_cliente = mc.n_cod_cliente);

-- 3º nível: despesas unitárias de uma (linha × categoria × mês), com nome do fornecedor.
CREATE OR REPLACE FUNCTION public.omie_dre_itens(p_month text, p_dre_code text, p_categoria text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'fornecedor', COALESCE(nullif(f.razao_social,''), l.fornecedor_cod::text),
    'valor', round(l.valor, 2),
    'data', to_char(l.competencia_data, 'DD/MM'),
    'doc', l.doc,
    'fonte', l.fonte) ORDER BY l.valor DESC), '[]'::jsonb)
  FROM public.omie_dre_lancamentos l
  JOIN public.omie_dre_mapa m ON m.codigo_categoria = l.codigo_categoria AND m.incluir AND m.dre_code IS NOT NULL
  LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
  LEFT JOIN public.omie_fornecedores f ON f.codigo_cliente = l.fornecedor_cod
  WHERE l.valido AND to_char(l.competencia_data, 'YYYY-MM') = p_month
    AND COALESCE(pj.dre_code, m.dre_code) = p_dre_code
    AND COALESCE(m.categoria_nome, m.codigo_categoria) = p_categoria;
$function$;
REVOKE ALL ON FUNCTION public.omie_dre_itens(text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.omie_dre_itens(text,text,text) TO service_role;
