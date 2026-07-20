-- Soma as linhas do DRE (Grupo R + C# de fonte Omie) por mês, via omie_despesas × omie_dre_mapa.
-- Competência = data_emissao; exclui CANCELADO e categorias incluir=false (dupla contagem/balanço).
-- Retorna mapa { dre_code -> valor } que o DreTable casa pelo campo `code` de cada linha.
CREATE OR REPLACE FUNCTION public.omie_dre_grupo_r(p_month text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_object_agg(dre_code, valor), '{}'::jsonb)
  FROM (
    SELECT m.dre_code, round(sum(d.valor), 2) AS valor
    FROM public.omie_despesas d
    JOIN public.omie_dre_mapa m ON m.codigo_categoria = d.codigo_categoria
    WHERE m.incluir AND m.dre_code IS NOT NULL
      AND d.status_titulo <> 'CANCELADO'
      AND to_char(d.data_emissao, 'YYYY-MM') = p_month
    GROUP BY m.dre_code
  ) s;
$function$;

REVOKE ALL ON FUNCTION public.omie_dre_grupo_r(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.omie_dre_grupo_r(text) TO service_role;
