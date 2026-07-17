-- Faturamento diário (válido) por canal: Shopee, TikTok, Amazon, B2B.
-- (O Mercado Livre já vem do ml_dre_diario.) Exclui o dia corrente (só dias completos).
CREATE OR REPLACE FUNCTION public.vendas_diarias_canais(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with linhas as (
    select 'sp'::text canal, (create_time at time zone 'America/Sao_Paulo')::date d, sum(selling_price) fat
    from public.shopee_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and selling_price is not null
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 2
    union all
    select 'tt', (create_time at time zone 'America/Sao_Paulo')::date, sum(fin_revenue)
    from public.tt_pedidos
    where to_char(create_time at time zone 'America/Sao_Paulo','YYYY-MM')=p_month
      and order_status<>'CANCELLED' and fin_filled
      and (create_time at time zone 'America/Sao_Paulo')::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 2
    union all
    select 'az', purchase_date::date, sum(total)
    from public.az_pedidos
    where to_char(purchase_date,'YYYY-MM')=p_month
      and status not in ('Canceled','Pending','Unfulfillable')
      and purchase_date::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 2
    union all
    select 'b2b', data_emissao::date, sum(valor_total)
    from public.b2b_notas
    where to_char(data_emissao,'YYYY-MM')=p_month and situacao in (6,7)
      and data_emissao::date < (now() at time zone 'America/Sao_Paulo')::date
    group by 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'canal', canal, 'data', to_char(d,'DD/MM'), 'fat', round(fat,2)
  ) order by d, canal), '[]'::jsonb)
  from linhas;
$function$;
