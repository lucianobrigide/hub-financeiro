-- Virada de mês (achado de 01/09/2026, sessão de conferência com o Luciano):
-- o ml-ads-item chamava ml_fill_ads_item(mês CORRENTE) — em 01/09 buscou '2026-09'
-- e o ADS por item de 31/08 ficou de fora (o card do ML mostrou R$ 351,84 no lugar
-- de ~R$ 6k; recuperado à mão com ml_fill_ads_item('2026-08') → R$ 5.650,55).
-- O magalu_cron_diario tinha o mesmo furo (magalu_ingest_orders() default = mês
-- corrente): 2 pedidos de 31/08 (R$ 562,99) só entraram com re-ingestão manual.
-- Regra nova: nos dias 1..3 do mês, varrer TAMBÉM o mês anterior.

create or replace function public.ml_fill_ads_item_cron()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_cur jsonb; v_prev jsonb := null;
  v_ini timestamptz := clock_timestamp();
begin
  v_cur := public.ml_fill_ads_item(to_char(v_hoje, 'YYYY-MM'));
  if extract(day from v_hoje) <= 3 then
    v_prev := public.ml_fill_ads_item(to_char(v_hoje - interval '3 days', 'YYYY-MM'));
  end if;
  insert into public.ml_cron_log(job, dia_alvo, sucesso, duracao_ms, mensagem)
  values ('ads_item', v_hoje,
          coalesce((v_cur->>'ok')::boolean, false)
            and coalesce((v_prev->>'ok')::boolean, true),
          round(extract(epoch from clock_timestamp() - v_ini) * 1000),
          'cur='||coalesce(v_cur->>'no_banco','?')||' fb='||coalesce(v_cur->>'fallback_campanha','0')
          ||case when v_prev is null then ''
                 else ' prev='||coalesce(v_prev->>'no_banco','?')||' fb_prev='||coalesce(v_prev->>'fallback_campanha','0') end);
  return jsonb_build_object('cur', v_cur, 'prev', v_prev);
end $$;

comment on function public.ml_fill_ads_item_cron() is
  'Wrapper do cron ml-ads-item: mês corrente sempre; nos dias 1..3 também o mês anterior (virada de mês). Loga em ml_cron_log job=ads_item.';

select cron.schedule('ml-ads-item', '25 6 * * *',
  $cmd$SET statement_timeout='300s'; SELECT public.ml_fill_ads_item_cron();$cmd$);

create or replace function public.magalu_cron_diario()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tok jsonb; v_ing jsonb; v_prev jsonb := null;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  v_tok := public.magalu_refresh_token(false);
  if coalesce((v_tok->>'valid')::boolean, false) is not true then
    return jsonb_build_object('ok', false, 'etapa', 'token', 'detail', v_tok);
  end if;
  v_ing := public.magalu_ingest_orders();
  if extract(day from v_hoje) <= 3 then
    v_prev := public.magalu_ingest_orders(to_char(v_hoje - interval '3 days', 'YYYY-MM'));
  end if;
  return jsonb_build_object(
    'ok', coalesce((v_ing->>'ok')::boolean, false)
          and coalesce((v_prev->>'ok')::boolean, true),
    'ingest', v_ing,
    'ingest_mes_anterior', v_prev);
end $$;
