-- TikTok — ciclo de vida do pedido + data real de liquidação (base dos recebíveis) · 22/08/2026
--
-- Pedido do Luciano (22/08): cronograma com data em TODAS as plataformas.
-- Medido ao vivo em 22/08 (99 pedidos dos 6 statements mais recentes):
--   • os statements do TikTok são DIÁRIOS (statement_time = 00:00 UTC de cada dia,
--     payment_time ~3h depois, status PAID) — o dinheiro sai no mesmo dia;
--   • um pedido entra no statement de (entrega + 6 dias): lag entrega→statement
--     p50 6,26d · p90 6,45d · mín 6,01d (máx 15,4d, outliers), ou seja, a data
--     UTC do statement = data UTC da entrega + 7.
-- O `delivery_time` vem do detalhe do pedido (`/order/202309/orders?ids=`, até 50
-- por chamada); `tt_pedidos` não guardava isso — esta migration adiciona as
-- colunas de ciclo e duas coletas:
--   • tt_fill_ciclo(limit): delivery/collection/rts_time dos pedidos pendentes e
--     dos liquidados recentes (base de backtest);
--   • tt_fill_statements(dias): statement_time REAL por pedido, lendo
--     `/finance/202309/statements` + `/finance/202501/statements/{id}/statement_transactions`
--     (a resposta vem em `data.transactions`, não `statement_transactions`; exige
--     sort_field). É o "crédito na carteira" do TikTok — base do detector.
-- O VALOR do recebível continua sendo decisão separada (card FORA DO TOTAL desde
-- 17/08: o repasse varia 84,6%–98,6% do pago); aqui só a DATA passa a existir.
alter table public.tt_pedidos
  add column if not exists delivery_time timestamptz,
  add column if not exists collection_time timestamptz,
  add column if not exists rts_time timestamptz,
  add column if not exists ciclo_atualizado_em timestamptz,
  add column if not exists statement_time timestamptz;

comment on column public.tt_pedidos.delivery_time is 'Entrega ao cliente (detalhe do pedido). Base da data derivada de liquidação (entrega + 6d → statement diário).';
comment on column public.tt_pedidos.statement_time is 'statement_time do statement diário em que o pedido foi liquidado (fato). Base do detector de acurácia.';

create or replace function public.tt_fill_ciclo(p_limit integer default 300)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
set statement_timeout to '240s'
as $$
declare
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_ids text; v_resp jsonb; v_o jsonb; v_lotes int := 0; v_upd int := 0; v_err text;
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name='tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name='tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher from public.tt_oauth_state where id=1;
  if v_app_key is null or v_access is null then return jsonb_build_object('error','missing_credentials'); end if;
  if (select expires_at from public.tt_oauth_state where id=1) < clock_timestamp() + interval '15 minutes' then
    perform public.tt_refresh_token(true);
    select access_token into v_access from public.tt_oauth_state where id=1;
  end if;

  -- Fila: pendentes de liquidação (sempre) + liquidados dos últimos 60d ainda sem
  -- ciclo (base de backtest, uma vez). Pedido sem entrega é re-checado a cada passada.
  for v_ids in
    with fila as (
      select order_id from public.tt_pedidos
      where order_status not in ('CANCELLED','UNPAID')
        and (
          (not fin_filled and (delivery_time is null or ciclo_atualizado_em < now() - interval '12 hours'))
          or (fin_filled and delivery_time is null and ciclo_atualizado_em is null and create_time >= now() - interval '60 days')
        )
      order by fin_filled, create_time
      limit p_limit
    ),
    num as (select order_id, (row_number() over (order by order_id) - 1) / 50 as g from fila)
    select string_agg(order_id, ',') from num group by g
  loop
    begin
      v_resp := public._tt_get('/order/202309/orders', jsonb_build_object('ids', v_ids), v_app_key, v_app_secret, v_access, v_cipher);
      if v_resp->>'error' is not null or coalesce((v_resp->>'code')::int, -1) <> 0 then
        raise exception 'orders: % %', coalesce(v_resp->>'error',''), left(coalesce(v_resp->>'message',''),120);
      end if;
      for v_o in select value from jsonb_array_elements(coalesce(v_resp->'data'->'orders','[]'::jsonb)) loop
        update public.tt_pedidos set
          order_status    = coalesce(v_o->>'status', order_status),
          delivery_time   = coalesce(to_timestamp(nullif(v_o->>'delivery_time','')::bigint), delivery_time),
          collection_time = coalesce(to_timestamp(nullif(v_o->>'collection_time','')::bigint), collection_time),
          rts_time        = coalesce(to_timestamp(nullif(v_o->>'rts_time','')::bigint), rts_time),
          ciclo_atualizado_em = now()
        where order_id = v_o->>'id';
        v_upd := v_upd + 1;
      end loop;
      v_lotes := v_lotes + 1;
    exception when others then
      v_err := coalesce(v_err || ' | ', '') || left(sqlerrm, 150);
    end;
    perform pg_sleep(0.2);
  end loop;

  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, pedidos, duracao_ms, mensagem)
  values (now(), 'tt_ciclo', (now() at time zone 'America/Sao_Paulo')::date, v_err is null, v_upd, null,
          format('%s lotes, %s pedidos atualizados%s', v_lotes, v_upd, coalesce(' — ' || v_err, '')));
  return jsonb_build_object('lotes', v_lotes, 'pedidos', v_upd, 'erros', v_err);
end $$;
revoke all on function public.tt_fill_ciclo(integer) from public, anon, authenticated;

-- statement_time REAL por pedido (últimos p_dias de statements).
create or replace function public.tt_fill_statements(p_dias integer default 14)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
set statement_timeout to '240s'
as $$
declare
  v_app_key text; v_app_secret text; v_access text; v_cipher text;
  v_resp jsonb; v_st jsonb; v_tx jsonb; v_token text; v_sts int := 0; v_ped int := 0; v_err text; v_pages int := 0;
  v_st_token text := '';
begin
  select decrypted_secret into v_app_key    from vault.decrypted_secrets where name='tt_app_key';
  select decrypted_secret into v_app_secret from vault.decrypted_secrets where name='tt_app_secret';
  select access_token, shop_cipher into v_access, v_cipher from public.tt_oauth_state where id=1;
  if v_app_key is null or v_access is null then return jsonb_build_object('error','missing_credentials'); end if;

  loop
    v_resp := public._tt_get('/finance/202309/statements',
      jsonb_build_object('page_size','50','sort_field','statement_time','sort_order','DESC',
                         'statement_time_ge', extract(epoch from now() - make_interval(days => p_dias))::bigint::text)
      || case when v_st_token <> '' then jsonb_build_object('page_token', v_st_token) else '{}'::jsonb end,
      v_app_key, v_app_secret, v_access, v_cipher);
    if v_resp->>'error' is not null or coalesce((v_resp->>'code')::int, -1) <> 0 then
      v_err := 'statements: ' || coalesce(v_resp->>'error','') || ' ' || left(coalesce(v_resp->>'message',''),120);
      exit;
    end if;
    for v_st in select value from jsonb_array_elements(coalesce(v_resp->'data'->'statements','[]'::jsonb)) loop
      v_sts := v_sts + 1;
      v_token := '';
      loop
        begin
          v_tx := public._tt_get('/finance/202501/statements/' || (v_st->>'id') || '/statement_transactions',
            jsonb_build_object('page_size','50','sort_field','order_create_time','sort_order','DESC')
            || case when v_token <> '' then jsonb_build_object('page_token', v_token) else '{}'::jsonb end,
            v_app_key, v_app_secret, v_access, v_cipher);
          if v_tx->>'error' is not null or coalesce((v_tx->>'code')::int, -1) <> 0 then
            raise exception 'tx % : % %', v_st->>'id', coalesce(v_tx->>'error',''), left(coalesce(v_tx->>'message',''),100);
          end if;
          v_pages := v_pages + 1;
          with t as (
            select distinct x->>'order_id' as oid
            from jsonb_array_elements(coalesce(v_tx->'data'->'transactions','[]'::jsonb)) x
            where x->>'type' = 'ORDER' and coalesce(x->>'order_id','') <> ''
          )
          update public.tt_pedidos p
             set statement_time = least(coalesce(p.statement_time, 'infinity'::timestamptz), to_timestamp((v_st->>'statement_time')::bigint))
            from t where p.order_id = t.oid;
          get diagnostics v_ped = row_count;
          v_token := coalesce(v_tx->'data'->>'next_page_token','');
        exception when others then
          v_err := coalesce(v_err || ' | ', '') || left(sqlerrm, 150);
          v_token := '';
        end;
        exit when v_token = '';
        perform pg_sleep(0.15);
      end loop;
      perform pg_sleep(0.15);
    end loop;
    v_st_token := coalesce(v_resp->'data'->>'next_page_token','');
    exit when v_st_token = '';
  end loop;

  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, pedidos, mensagem)
  values (now(), 'tt_statements', (now() at time zone 'America/Sao_Paulo')::date, v_err is null,
          (select count(*) from public.tt_pedidos where statement_time >= now() - make_interval(days => p_dias)),
          format('%s statements, %s páginas de transações%s', v_sts, v_pages, coalesce(' — ' || v_err, '')));
  return jsonb_build_object('statements', v_sts, 'paginas', v_pages, 'erros', v_err,
    'pedidos_com_statement', (select count(*) from public.tt_pedidos where statement_time is not null));
end $$;
revoke all on function public.tt_fill_statements(integer) from public, anon, authenticated;

-- Cron: depois do tt-diario (04:00 BRT) — 04:20 BRT; e reforço 13:30 BRT.
select cron.schedule('tt-ciclo', '20 7,16 * * *',
  $$select public.tt_fill_ciclo(300); select public.tt_fill_statements(14);$$);

-- Catálogo da página /crons.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';
  if position('tt-ciclo' in v_def) > 0 then
    raise notice 'catálogo já tem tt-ciclo'; return;
  end if;
  v_row := $r$('tt-ciclo','TikTok','diario','Todo dia às 04:20 e 13:30 BRT',
     'Busca a data de entrega de cada pedido do TikTok ainda não liquidado e a data real dos statements diários — é o que dá DATA aos recebíveis do TikTok no F.C. Projetado (liquida em entrega + 6 dias).',
     'honesto', 16, null),
    $r$;
  v_new := replace(v_def, '(''ml-semanal'',''Mercado Livre'',''semanal''', v_row || '(''ml-semanal'',''Mercado Livre'',''semanal''');
  if v_new = v_def then raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado'; end if;
  execute v_new;
end
$do$;
