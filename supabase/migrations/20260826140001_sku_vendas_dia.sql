-- sku_vendas_dia: UNIDADES vendidas por SKU × dia, TODOS os canais somados (pedido do
-- Luciano 26/08: tabela no dashboard principal com todos os SKUs e a quantidade de vendas
-- por dia, com filtro de dias — o filtro vive no client, a RPC devolve o mês inteiro).
--
-- Réguas de contagem = as mesmas da bruta de cada canal (espelham dre_sku/faturamento):
--   ML       paid + partially_refunded (competência p.data)
--   Shopee   não-cancelados/não-UNPAID (create_time @ SP)
--   TikTok   pago antes de liquidar: exclui UNPAID/CANCELLED + item line_status<>CANCELLED
--   Amazon   status ∉ Canceled/Pending/Unfulfillable (purchase_date)
--   B2B      situação 6/7 (data_emissao)
--   SHEIN    status ∉ 6/8/9, 1 unidade por goodsId (payment_time @ SP)
--   Magalu   status <> cancelled (created_at @ SP)
-- Dia corrente FORA (d < hoje BRT), igual ao dre_sku: os pedidos entram nos crons da
-- madrugada — "hoje" apareceria como venda baixa falsa.
-- SKU unificado por unaccent (padrão do ml_custo_produto) para o mesmo produto somar
-- entre canais; SKU vazio vira '(sem SKU)' em vez de sumir.

CREATE OR REPLACE FUNCTION public.sku_vendas_dia(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with
  ml as (
    select coalesce(nullif(unaccent(i.sku),''),'(sem SKU)') sku, max(i.titulo) titulo,
      p.data::date d, sum(i.quantidade)::int qtd
    from public.ml_pedido_itens i
    join public.ml_pedidos p on p.pedido_id=i.pedido_id
    where to_char(p.data,'YYYY-MM')=p_month and p.status in ('paid','partially_refunded')
      and p.data < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  sp as (
    select coalesce(nullif(unaccent(coalesce(nullif(i.model_sku,''), i.item_sku)),''),'(sem SKU)') sku,
      max(i.item_name) titulo,
      (p.create_time at time zone 'America/Sao_Paulo')::date d, sum(i.quantity)::int qtd
    from public.shopee_itens i join public.shopee_pedidos p on p.order_sn=i.order_sn
    where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and (p.create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  tt as (
    select coalesce(nullif(unaccent(i.seller_sku),''),'(sem SKU)') sku, max(i.product_name) titulo,
      (p.create_time at time zone 'America/Sao_Paulo')::date d, sum(i.quantity)::int qtd
    from public.tt_itens i join public.tt_pedidos p on p.order_id=i.order_id
    where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in ('UNPAID','CANCELLED') and i.line_status<>'CANCELLED'
      and (p.create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  az as (
    select coalesce(nullif(unaccent(i.seller_sku),''),'(sem SKU)') sku, max(i.asin) titulo,
      p.purchase_date::date d, sum(i.quantidade)::int qtd
    from public.az_itens i join public.az_pedidos p on p.amazon_order_id=i.amazon_order_id
    where to_char(p.purchase_date,'YYYY-MM')=p_month
      and p.status not in ('Canceled','Pending','Unfulfillable')
      and p.purchase_date::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  b2b as (
    select coalesce(nullif(unaccent(i.sku),''),'(sem SKU)') sku, max(i.descricao) titulo,
      n.data_emissao::date d, sum(i.quantidade)::int qtd
    from public.b2b_itens i join public.b2b_notas n on n.id=i.nota_id
    where to_char(n.data_emissao,'YYYY-MM')=p_month and n.situacao in (6,7)
      and n.data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  sh as (
    select coalesce(nullif(unaccent(i.seller_sku),''),'(sem SKU)') sku, max(i.goods_title) titulo,
      (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date d,
      count(*)::int qtd
    from public.shein_itens i join public.shein_pedidos p on p.order_no=i.order_no
    where to_char(coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.order_status not in (6,8,9)
      and (coalesce(p.payment_time, p.order_time) at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  mg as (
    select coalesce(nullif(unaccent(i.sku),''),'(sem SKU)') sku, max(i.product_name) titulo,
      (p.created_at at time zone 'America/Sao_Paulo')::date d, sum(i.quantity)::int qtd
    from public.magalu_itens i join public.magalu_pedidos p on p.code=i.code
    where to_char(p.created_at at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and p.status <> 'cancelled'
      and (p.created_at at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 1,3
  ),
  todos as (
    select * from ml union all select * from sp union all select * from tt
    union all select * from az union all select * from b2b union all select * from sh
    union all select * from mg
  ),
  agg as (select sku, max(titulo) titulo, d, sum(qtd)::int qtd from todos group by sku, d)
  select coalesce(jsonb_agg(jsonb_build_object(
    'sku',sku,'titulo',titulo,'data',to_char(d,'DD/MM'),'qtd',qtd
  ) order by d, sku),'[]'::jsonb) from agg;
$function$;

COMMENT ON FUNCTION public.sku_vendas_dia(text) IS
  'Unidades vendidas por SKU × dia (todos os canais) para a tabela do dashboard principal. Réguas de status = bruta de cada canal; dia corrente fora (crons ingerem na madrugada).';
