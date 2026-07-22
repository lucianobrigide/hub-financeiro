-- Fonte unificada do DRE: Contas a Pagar + movimentos de conta corrente GENUÍNOS.
-- Genuíno = n_cod_titulo=0 (não é baixa de AP) E fornecedor não é de plataforma (Hub já capta).
-- Competência: AP = emissão (fallback vencimento); CC = data de pagamento.
CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
  SELECT codigo_categoria,
         raw->>'codigo_projeto' AS codigo_projeto,
         valor,
         COALESCE(data_emissao, data_vencimento) AS competencia_data,
         (status_titulo <> 'CANCELADO') AS valido
  FROM public.omie_despesas
  UNION ALL
  SELECT codigo_categoria, codigo_projeto, valor,
         data_pagamento AS competencia_data,
         (c_status <> 'CANCELADO') AS valido
  FROM public.omie_mov_cc mc
  WHERE COALESCE(mc.n_cod_titulo, 0) = 0
    AND NOT EXISTS (SELECT 1 FROM public.omie_forn_plataforma p WHERE p.codigo_cliente = mc.n_cod_cliente);
GRANT SELECT ON public.omie_dre_lancamentos TO service_role;

-- RPCs leem a view (AP + CC). Linha = projeto (fallback categoria); include = categoria.
CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT COALESCE(jsonb_object_agg(dre_code, valor), '{}'::jsonb)
  FROM (
    SELECT COALESCE(pj.dre_code, m.dre_code) AS dre_code, round(sum(l.valor), 2) AS valor
    FROM public.omie_dre_lancamentos l
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = l.codigo_categoria AND m.incluir AND m.dre_code IS NOT NULL
    LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
    WHERE l.valido AND to_char(l.competencia_data, 'YYYY-MM') = p_month
    GROUP BY COALESCE(pj.dre_code, m.dre_code)
  ) s;
$function$;

CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r_detalhe(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dre_code', dre_code, 'nome', nome, 'valor', valor)
                            ORDER BY dre_code, valor DESC), '[]'::jsonb)
  FROM (
    SELECT COALESCE(pj.dre_code, m.dre_code) AS dre_code,
           COALESCE(m.categoria_nome, m.codigo_categoria) AS nome,
           round(sum(l.valor), 2) AS valor
    FROM public.omie_dre_lancamentos l
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = l.codigo_categoria AND m.incluir AND m.dre_code IS NOT NULL
    LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = l.codigo_projeto
    WHERE l.valido AND to_char(l.competencia_data, 'YYYY-MM') = p_month
    GROUP BY COALESCE(pj.dre_code, m.dre_code), COALESCE(m.categoria_nome, m.codigo_categoria)
    HAVING round(sum(l.valor), 2) <> 0
  ) s;
$function$;
