-- Linha do DRE = projeto (fallback categoria); include/exclude = categoria; drill-down = categoria.
-- Não muda o resultado: o conjunto incluído é o mesmo (filtro por categoria); só a linha muda.
CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT COALESCE(jsonb_object_agg(dre_code, valor), '{}'::jsonb)
  FROM (
    SELECT COALESCE(pj.dre_code, m.dre_code) AS dre_code, round(sum(d.valor), 2) AS valor
    FROM public.omie_despesas d
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = d.codigo_categoria
    LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = d.raw->>'codigo_projeto'
    WHERE m.incluir AND m.dre_code IS NOT NULL
      AND d.status_titulo <> 'CANCELADO'
      AND to_char(COALESCE(d.data_emissao, d.data_vencimento), 'YYYY-MM') = p_month
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
           round(sum(d.valor), 2) AS valor
    FROM public.omie_despesas d
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = d.codigo_categoria
    LEFT JOIN public.omie_projeto_dre pj ON pj.codigo_projeto = d.raw->>'codigo_projeto'
    WHERE m.incluir AND m.dre_code IS NOT NULL
      AND d.status_titulo <> 'CANCELADO'
      AND to_char(COALESCE(d.data_emissao, d.data_vencimento), 'YYYY-MM') = p_month
    GROUP BY COALESCE(pj.dre_code, m.dre_code), COALESCE(m.categoria_nome, m.codigo_categoria)
    HAVING round(sum(d.valor), 2) <> 0
  ) s;
$function$;
