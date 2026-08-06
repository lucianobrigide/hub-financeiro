-- Tráfego pago em categoria excluída entra no DRE via projeto (Luciano, 05/08/2026).
--
-- CONTEXTO: a categoria 2.01.96 "Serviços Essenciais" é excluída do DRE porque
-- concentra custos de plataforma que o Hub já captura por API (comissão de
-- intermediação, coletas TikTok Logistics) — incluir seria dupla contagem. E ela
-- NÃO pode ser trocada na Omie: o financeiro recupera crédito sobre esses valores.
-- Porém as NFs de TRÁFEGO PAGO da Bytedance (TikTok Ads Manager — anúncio de
-- marca/site, cobrado por fora, fora do settlement) também são lançadas nela,
-- e esse custo NÃO vem de API nenhuma → estava sumindo de todo lugar
-- (R$ 502,65 em jul/2026; ~R$ 4,2k desde out/2025).
--
-- REGRA (decisão Luciano): lançamento em categoria excluída ENTRA no DRE quando
-- o PROJETO dele estiver marcado com `forca_inclusao` — hoje, só o projeto
-- "Marketing & Tráfego" (→ C1). Coletas/intermediações têm outros projetos e
-- continuam fora. ⚠️ Só marcar forca_inclusao em projeto cujo custo NÃO é
-- capturado por API de marketplace — senão vira dupla contagem.

ALTER TABLE public.omie_projeto_dre ADD COLUMN IF NOT EXISTS forca_inclusao boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.omie_projeto_dre.forca_inclusao IS
  'true = lançamentos deste projeto entram no DRE mesmo quando a categoria está excluída no omie_dre_mapa (uso: tráfego pago em 2.01.96, que não vem de API). Nunca marcar em projeto cujo custo já vem de API de marketplace.';

UPDATE public.omie_projeto_dre SET forca_inclusao = true WHERE codigo_projeto = '10743558033';  -- Marketing & Tráfego → C1

-- Nome legível no drill-down (a linha 2.01.96 não tinha categoria_nome)
UPDATE public.omie_dre_mapa SET categoria_nome = 'Serviços Essenciais' WHERE codigo_categoria = '2.01.96' AND categoria_nome IS NULL;

-- As 3 funções do DRE ganham o mesmo OR: (categoria incluída) OU (projeto com força)

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
      AND ( (m.incluir AND m.dre_code IS NOT NULL)
         OR (pj.forca_inclusao AND pj.dre_code IS NOT NULL) )
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
      AND ( (m.incluir AND m.dre_code IS NOT NULL)
         OR (pj.forca_inclusao AND pj.dre_code IS NOT NULL) )
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
    AND ( (m.incluir AND m.dre_code IS NOT NULL)
       OR (pj.forca_inclusao AND pj.dre_code IS NOT NULL) )
    AND COALESCE(pj.dre_code, m.dre_code) = p_dre_code
    AND COALESCE(m.categoria_nome, m.codigo_categoria, l.codigo_categoria) = p_categoria;
$function$;
