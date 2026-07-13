-- Ordena os pendentes por purchase_date ASC (mais antigos primeiro) — assim o batch do
-- confirmar processa os pedidos mais prováveis de já estarem liquidados na Amazon, e o
-- loop do cron confirma o máximo por run antes de parar. Antes: sem ORDER BY (ordem física).
CREATE OR REPLACE FUNCTION public.az_pendentes_comissao()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
AS $function$
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('amazon_order_id', c.amazon_order_id, 'comissao_estimada', c.comissao_estimada)
    ORDER BY p.purchase_date ASC NULLS LAST
  ), '[]'::jsonb)
  FROM public.az_comissao c
  LEFT JOIN public.az_pedidos p ON p.amazon_order_id = c.amazon_order_id
  WHERE NOT c.confirmado;
$function$;

CREATE OR REPLACE FUNCTION public.az_pendentes_frete()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
AS $function$
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object('amazon_order_id', f.amazon_order_id, 'frete_estimado', f.frete_estimado)
    ORDER BY p.purchase_date ASC NULLS LAST
  ), '[]'::jsonb)
  FROM public.az_frete f
  LEFT JOIN public.az_pedidos p ON p.amazon_order_id = f.amazon_order_id
  WHERE NOT f.confirmado;
$function$;

REVOKE ALL ON FUNCTION public.az_pendentes_comissao() FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.az_pendentes_frete() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.az_pendentes_comissao() TO service_role;
GRANT EXECUTE ON FUNCTION public.az_pendentes_frete() TO service_role;
