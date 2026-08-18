-- ============================================================================
-- Shopee — ciclo de vida do pedido (Fase 1 dos recebíveis com data) · 18/08/2026
-- ============================================================================
-- DESCOBERTA (Fase 0, 18/08/2026, medida em 14.434 pedidos já liberados):
--   • A liberação do escrow É o momento em que o pedido vira COMPLETED:
--     update_time do pedido = crédito ESCROW_VERIFIED_ADD na carteira em ±5min
--     em 99,40% dos casos (86 restantes = evento posterior tocou o update_time;
--     ZERO casos de liberação atrasada vs conclusão).
--   • O pedido conclui quando o comprador clica "Pedido Recebido" OU quando a
--     Garantia Shopee expira (entrega + 7 dias; return_request_due_date =
--     delivered + 7d EXATOS, validado por tracking).
--   • Distribuição entrega→liberação (405 pedidos com tracking): 65,8% liberam
--     entre D+0 e D+7 (confirmação antecipada; 32,6% já em D+0..1), 27,2% no
--     cluster D+7..8 (auto-conclusão), 7,2% em D+8..10 (processamento/fim de
--     semana); máx. observado 9,93d. "Entrega + 7~8d" é o teto contratual.
--   • edt_* e return_request_due_date SOMEM da resposta depois que o pedido
--     conclui — por isso a coleta é no pedido PENDENTE, com coalesce (nunca
--     sobrescrever com null um valor que a API parou de mandar).
--
-- Esta migration só INGERE o ciclo de vida (status atual + entrega + prazos).
-- Nenhuma régua de card muda aqui; o cronograma do F.C. Projetado é a Fase 2
-- (aguardando decisão do Luciano sobre a REGRA DURA — data derivada com selo).
-- Efeito colateral desejado: order_status dos pendentes fica fresco, o que
-- melhora as 3 exclusões do em_disputa (TO_RETURN era detectado com status
-- defasado — pedido liberado constava READY_TO_SHIP).

alter table shopee_pedidos
  add column if not exists status_update_time      timestamptz,
  add column if not exists pickup_done_time        timestamptz,
  add column if not exists delivered_time          timestamptz,
  add column if not exists edt_from                timestamptz,
  add column if not exists edt_to                  timestamptz,
  add column if not exists return_request_due_date timestamptz,
  add column if not exists ciclo_atualizado_em     timestamptz;

comment on column shopee_pedidos.status_update_time is
  'update_time do get_order_detail. Quando o status é COMPLETED, é o momento da liberação do escrow (validado: 99,40% ±5min em 14.434 pedidos).';
comment on column shopee_pedidos.delivered_time is
  'Evento DELIVERED do get_tracking_info (1 chamada/pedido — só para pendentes entregues). Âncora do cronograma de recebíveis.';
comment on column shopee_pedidos.return_request_due_date is
  'Fim da Garantia Shopee = entrega + 7d exatos. Some da API após a conclusão (por isso coalesce na ingestão).';
comment on column shopee_pedidos.ciclo_atualizado_em is
  'Última passada do shopee_fill_ciclo neste pedido.';

create or replace function shopee_fill_ciclo(p_max_det int default 20, p_max_trk int default 120)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_pid text; v_pkey text; v_tok text; v_shop bigint;
  v_ini timestamptz := clock_timestamp();
  v_lote text[]; v_resp jsonb; v_x jsonb;
  v_det_calls int := 0; v_det_pedidos int := 0;
  v_trk_calls int := 0; v_trk_entregas int := 0;
  v_sn text; v_del timestamptz;
  v_erro text := null;
begin
  if not pg_try_advisory_lock(hashtext('shopee_fill_ciclo')) then
    return jsonb_build_object('ok', false, 'mensagem', 'já existe uma execução rodando');
  end if;

  select decrypted_secret into v_pid  from vault.decrypted_secrets where name='shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name='shopee_partner_key';
  select access_token, shop_id into v_tok, v_shop from shopee_oauth_state where id=1;
  if v_pid is null or v_pkey is null or v_tok is null then
    perform pg_advisory_unlock(hashtext('shopee_fill_ciclo'));
    return jsonb_build_object('ok', false, 'mensagem', 'sem credenciais da Shopee');
  end if;
  if (select expires_at from shopee_oauth_state where id=1) < clock_timestamp() + interval '10 minutes' then
    perform shopee_refresh_token(true);
    select access_token into v_tok from shopee_oauth_state where id=1;
  end if;

  -- ── FASE A: get_order_detail em lotes de 50, universo = pendentes do recebível
  -- (mesma base do shopee_recebiveis: não-cancelado, com escrow, dentro da
  -- janela da carteira, sem crédito ainda). Guarda de 6h para o loop terminar.
  while v_det_calls < p_max_det loop
    select array_agg(order_sn) into v_lote from (
      with cobertura as (select min(create_time) as desde from shopee_wallet),
      mov as (
        select order_sn, bool_or(transaction_type='ESCROW_VERIFIED_ADD') as teve_credito
        from shopee_wallet
        where order_sn is not null and order_sn <> ''
        group by order_sn
      )
      select p.order_sn
      from shopee_pedidos p
      left join mov m on m.order_sn = p.order_sn
      cross join cobertura c
      where p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
        and coalesce(p.escrow_adjusted, p.escrow_amount) is not null
        and p.create_time >= c.desde
        and coalesce(m.teve_credito, false) = false
        and (p.ciclo_atualizado_em is null or p.ciclo_atualizado_em < v_ini - interval '6 hours')
      order by p.ciclo_atualizado_em asc nulls first, p.create_time asc
      limit 50
    ) s;
    exit when v_lote is null;

    begin
      v_resp := _sp_api_get('/api/v2/order/get_order_detail',
        'order_sn_list=' || array_to_string(v_lote, ',')
        || '&response_optional_fields=pickup_done_time,edt_from,edt_to,return_request_due_date',
        v_pid, v_pkey, v_tok, v_shop);
      if coalesce(v_resp->>'error','') <> '' then
        raise exception 'API detail: % — %', v_resp->>'error', coalesce(v_resp->>'message','');
      end if;

      for v_x in select * from jsonb_array_elements(coalesce(v_resp->'response'->'order_list','[]'::jsonb)) loop
        update shopee_pedidos set
          order_status       = coalesce(v_x->>'order_status', order_status),
          status_update_time = case when coalesce((v_x->>'update_time')::bigint,0) > 0
                                    then to_timestamp((v_x->>'update_time')::bigint) else status_update_time end,
          -- campos que a API para de mandar depois da conclusão: nunca anular
          pickup_done_time        = coalesce(case when coalesce((v_x->>'pickup_done_time')::bigint,0) > 0
                                                  then to_timestamp((v_x->>'pickup_done_time')::bigint) end, pickup_done_time),
          edt_from                = coalesce(case when coalesce((v_x->>'edt_from')::bigint,0) > 0
                                                  then to_timestamp((v_x->>'edt_from')::bigint) end, edt_from),
          edt_to                  = coalesce(case when coalesce((v_x->>'edt_to')::bigint,0) > 0
                                                  then to_timestamp((v_x->>'edt_to')::bigint) end, edt_to),
          return_request_due_date = coalesce(case when coalesce((v_x->>'return_request_due_date')::bigint,0) > 0
                                                  then to_timestamp((v_x->>'return_request_due_date')::bigint) end, return_request_due_date)
        where order_sn = v_x->>'order_sn';
        v_det_pedidos := v_det_pedidos + 1;
      end loop;

      -- carimba o lote inteiro (inclusive não-retornados) para o loop avançar
      update shopee_pedidos set ciclo_atualizado_em = clock_timestamp()
      where order_sn = any(v_lote);
    exception when others then
      v_erro := 'fase detail (lote ' || (v_det_calls+1) || '): ' || sqlerrm;
      exit;
    end;

    v_det_calls := v_det_calls + 1;
  end loop;

  -- ── FASE B: get_tracking_info (1 chamada/pedido) só para pendentes ENTREGUES
  -- (TO_CONFIRM_RECEIVE) ainda sem delivered_time. Re-tenta no próximo run se o
  -- tracking ainda não tiver o evento DELIVERED.
  if v_erro is null then
    for v_sn in
      with cobertura as (select min(create_time) as desde from shopee_wallet),
      mov as (
        select order_sn, bool_or(transaction_type='ESCROW_VERIFIED_ADD') as teve_credito
        from shopee_wallet
        where order_sn is not null and order_sn <> ''
        group by order_sn
      )
      select p.order_sn
      from shopee_pedidos p
      left join mov m on m.order_sn = p.order_sn
      cross join cobertura c
      where p.order_status = 'TO_CONFIRM_RECEIVE'
        and p.delivered_time is null
        and coalesce(p.escrow_adjusted, p.escrow_amount) is not null
        and p.create_time >= c.desde
        and coalesce(m.teve_credito, false) = false
      order by p.status_update_time asc nulls first
      limit p_max_trk
    loop
      begin
        v_resp := _sp_api_get('/api/v2/logistics/get_tracking_info',
                              'order_sn=' || v_sn, v_pid, v_pkey, v_tok, v_shop);
        if coalesce(v_resp->>'error','') <> '' then
          raise exception 'API tracking: % — %', v_resp->>'error', coalesce(v_resp->>'message','');
        end if;
        v_del := null;
        select to_timestamp(max((e->>'update_time')::bigint)) into v_del
        from jsonb_array_elements(coalesce(v_resp->'response'->'tracking_info','[]'::jsonb)) e
        where e->>'logistics_status' = 'DELIVERED';
        if v_del is not null then
          update shopee_pedidos set delivered_time = v_del where order_sn = v_sn;
          v_trk_entregas := v_trk_entregas + 1;
        end if;
      exception when others then
        v_erro := 'fase tracking (' || v_sn || '): ' || sqlerrm;
        exit;
      end;
      v_trk_calls := v_trk_calls + 1;
    end loop;
  end if;

  perform pg_advisory_unlock(hashtext('shopee_fill_ciclo'));

  insert into ml_cron_log(job, sucesso, pedidos, duracao_ms, mensagem, resposta)
  values ('shopee_ciclo', v_erro is null, v_det_pedidos,
          (extract(epoch from (clock_timestamp()-v_ini))*1000)::int,
          coalesce(v_erro, 'ok — ' || v_det_pedidos || ' detalhes em ' || v_det_calls
                   || ' lotes; ' || v_trk_entregas || ' entregas em ' || v_trk_calls || ' trackings'),
          jsonb_build_object('det_calls', v_det_calls, 'det_pedidos', v_det_pedidos,
                             'trk_calls', v_trk_calls, 'trk_entregas', v_trk_entregas));

  return jsonb_build_object('ok', v_erro is null, 'det_calls', v_det_calls,
                            'det_pedidos', v_det_pedidos, 'trk_calls', v_trk_calls,
                            'trk_entregas', v_trk_entregas, 'mensagem', coalesce(v_erro,'ok'));
end;
$function$;

comment on function shopee_fill_ciclo(int, int) is
  'Ingere o ciclo de vida dos pedidos pendentes de recebível Shopee (status atual em lotes de 50 + entrega via tracking). Base da Fase 2 do cronograma de recebíveis; também deixa o em_disputa do shopee_recebiveis preciso.';

revoke all on function shopee_fill_ciclo(int, int) from public, anon, authenticated;
grant execute on function shopee_fill_ciclo(int, int) to service_role;
