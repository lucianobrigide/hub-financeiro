-- ============================================================
-- Shopee: blindagem do SUM(NULL)→0 na régua VIVA (sp_repasse), sem mudar régua.
--
-- A M.C. Shopee do dashboard vem de sp_repasse (escrow real): comFreteReal = (bruta − repasse)
-- − afiliados. sp_comissao/sp_frete NÃO alimentam o app (órfãs — ver COMMENT abaixo).
-- Risco de SUM(NULL)→0: um pedido não-cancelado SEM escrow entra na bruta a preço cheio e
-- contribui 0 ao repasse → (bruta − repasse) trata todo o preço como retido → M.C. pessimista
-- naquele pedido (mesma classe do drift do TikTok, direção oposta).
--
-- Fix, SEM tocar no WHERE (mesmos pedidos contam): expor o SUBCONJUNTO com escrow para (a) a
-- cobertura ponderada por receita do piso e (b) a M.C. acima do piso sair sobre o mesmo conjunto
-- dos dois lados. Marcador "tem escrow" = escrow_adjusted IS NOT NULL (a coluna que o próprio
-- shopee_fill_escrow usa como gatilho; verificado 28/07/2026: bate linha a linha com
-- net_commission IS NOT NULL em jun e jul, divergência = 0).
--
-- Jun e jul têm 100% de escrow → subconjunto = total → nada se move. (Luciano, 28/07/2026.)
-- ============================================================

-- 1. sp_repasse: + bruta/repasse do subconjunto com escrow (WHERE inalterado)
CREATE OR REPLACE FUNCTION public.sp_repasse(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  SELECT jsonb_build_object(
    'repasse_total',        COALESCE(SUM(escrow_amount), 0),
    'pedidos_total',        COUNT(*),
    'pedidos_com_repasse',  COUNT(*) FILTER (WHERE escrow_amount > 0),
    'pedidos_zero',         COUNT(*) FILTER (WHERE escrow_amount = 0),
    'pedidos_neg',          COUNT(*) FILTER (WHERE escrow_amount < 0),
    'bruta_com_escrow',     COALESCE(SUM(selling_price) FILTER (WHERE escrow_adjusted IS NOT NULL AND selling_price IS NOT NULL), 0),
    'repasse_com_escrow',   COALESCE(SUM(escrow_amount)  FILTER (WHERE escrow_adjusted IS NOT NULL), 0)
  )
  FROM public.shopee_pedidos
  WHERE to_char(create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING');
$function$;

-- 2. sp_cmv: + cmv do subconjunto com escrow (WHERE inalterado)
CREATE OR REPLACE FUNCTION public.sp_cmv(p_month text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $function$
  SELECT jsonb_build_object(
    'cmv_total',       COALESCE(SUM(c.custo * i.quantity), 0),
    'cmv_com_escrow',  COALESCE(SUM(c.custo * i.quantity) FILTER (WHERE p.escrow_adjusted IS NOT NULL), 0),
    'itens_com_custo', COUNT(*) FILTER (WHERE c.custo IS NOT NULL),
    'itens_total',     COUNT(*)
  )
  FROM public.shopee_itens i
  JOIN public.shopee_pedidos p ON p.order_sn = i.order_sn
  LEFT JOIN public.ml_custo_produto c
    ON c.sku = unaccent(COALESCE(NULLIF(i.model_sku, ''), i.item_sku))
  WHERE to_char(p.create_time AT TIME ZONE 'America/Sao_Paulo', 'YYYY-MM') = p_month
    AND p.order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
    AND p.selling_price IS NOT NULL;
$function$;

-- 3. Marcar as órfãs NO OBJETO (aviso onde a pessoa realmente olha: ao ler a função)
COMMENT ON FUNCTION public.sp_comissao(text) IS 'ÓRFÃ — não alimenta o app. A régua viva da M.C. Shopee é sp_repasse (escrow real).';
COMMENT ON FUNCTION public.sp_frete(text)    IS 'ÓRFÃ — não alimenta o app. A régua viva da M.C. Shopee é sp_repasse (escrow real).';

REVOKE ALL ON FUNCTION public.sp_repasse(text) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.sp_cmv(text)     FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sp_repasse(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sp_cmv(text)     TO service_role;
