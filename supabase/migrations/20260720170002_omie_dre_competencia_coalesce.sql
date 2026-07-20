-- Competência do DRE = data de emissão; quando o título não tem emissão (ex.: parcelas de
-- DIFAL da Bahia, alguns aluguéis/SaaS lançados só com vencimento), cai no vencimento.
-- Antes esses títulos sem emissão eram silenciosamente descartados do DRE — o COALESCE
-- os traz de volta no mês do vencimento (revelou, p.ex., o aluguel que estava sumido).
CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT COALESCE(jsonb_object_agg(dre_code, valor), '{}'::jsonb)
  FROM (
    SELECT m.dre_code, round(sum(d.valor), 2) AS valor
    FROM public.omie_despesas d
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = d.codigo_categoria
    WHERE m.incluir AND m.dre_code IS NOT NULL
      AND d.status_titulo <> 'CANCELADO'
      AND to_char(COALESCE(d.data_emissao, d.data_vencimento), 'YYYY-MM') = p_month
    GROUP BY m.dre_code
  ) s;
$function$;

CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r_detalhe(p_month text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('dre_code', dre_code, 'nome', nome, 'valor', valor)
                            ORDER BY dre_code, valor DESC), '[]'::jsonb)
  FROM (
    SELECT m.dre_code, COALESCE(m.categoria_nome, m.codigo_categoria) AS nome, round(sum(d.valor), 2) AS valor
    FROM public.omie_despesas d
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = d.codigo_categoria
    WHERE m.incluir AND m.dre_code IS NOT NULL
      AND d.status_titulo <> 'CANCELADO'
      AND to_char(COALESCE(d.data_emissao, d.data_vencimento), 'YYYY-MM') = p_month
    GROUP BY m.dre_code, COALESCE(m.categoria_nome, m.codigo_categoria)
    HAVING round(sum(d.valor), 2) <> 0
  ) s;
$function$;
