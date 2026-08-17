-- ============================================================================
-- Mercado Pago — recebíveis (aba F.C. Projetado)  ·  17/08/2026
-- ============================================================================
--
-- CREDENCIAL: **não existe app/OAuth separado do Mercado Pago.** O access_token
-- que já mantemos para o Mercado Livre (ml_oauth_state, refresh a cada 30 min)
-- autentica em api.mercadopago.com — testado 17/08/2026: GET /users/me → 200,
-- user 494625660 (BRIGIDE STORE, MLB). Por isso esta ingestão NÃO tem token,
-- refresh, Vault nem keepalive próprios: pega o token via ml_get_state().
--
-- RÉGUA DO RECEBÍVEL (dinheiro, não competência):
--   recebível = pagamento status='approved' com money_release_status='pending'
--   e money_release_date >= hoje (BRT).
--   valor = transaction_details.net_received_amount − transaction_amount_refunded
--
--   net_received_amount é o líquido REAL que cai na conta, já deduzido de tudo
--   que o ML/MP retém — provado no pagamento 172744564388 (charges_details):
--     199,90 (bruto)
--     −  9,87  ml_sale_fee        (comissão ML)
--     − 25,55  shp_fulfillment    (frete Full)
--     −  0,07  mp_processing_fee  (taxa MP)
--     −  9,99  coupon_fee         (cupom bancado pelo vendedor)
--     = 154,42 = net_received_amount  ✓ centavo a centavo
--
--   NADA é estimado (REGRA DURA): o número vem pronto da API. `charges` guarda
--   a composição por pagamento para auditoria — sem dado do comprador (PII).
--
-- API (verificado 17/08/2026):
--   GET /v1/payments/search
--       ?range=money_release_date&begin_date=NOW-3DAYS&end_date=NOW+120DAYS
--       &status=approved&sort=money_release_date&criteria=asc&limit=100&offset=N
--   Aceita offset alto (testado 7000, sem cap) → varre a janela inteira sem
--   janelar por data. Cauda de liberação termina dentro de 90 dias (o total é
--   idêntico em +90d, +180d, +365d e +730d: 9.016 pagamentos), por isso 120 dias
--   de horizonte cobrem tudo com folga.
-- ============================================================================

create table if not exists mp_pagamentos (
  payment_id      bigint primary key,
  order_id        text,                       -- pedido do ML (order.id)
  status          text not null,              -- approved | refunded | cancelled ...
  status_detail   text,
  release_status  text,                       -- money_release_status: pending | released
  release_date    timestamptz,                -- money_release_date: o DIA em que o dinheiro cai
  date_approved   timestamptz,
  date_created    timestamptz,
  valor_bruto     numeric(14,2),              -- transaction_amount
  valor_liquido   numeric(14,2),              -- transaction_details.net_received_amount
  valor_estornado numeric(14,2) not null default 0,  -- transaction_amount_refunded
  operation_type  text,
  charges         jsonb,                      -- charges_details: composição das deduções (sem PII)
  atualizado_em   timestamptz not null default now()
);

comment on table mp_pagamentos is
  'Pagamentos do Mercado Pago (vendas do ML) para o cronograma de recebíveis do F.C. Projetado. '
  'valor_liquido = net_received_amount: o que cai de fato, já deduzido de comissão ML, frete, taxa MP e cupom.';

create index if not exists mp_pagamentos_release_idx
  on mp_pagamentos (release_date)
  where release_status = 'pending';

-- ─────────────────────────────────────────────────────────────────────────────
-- Ingestão: varre a janela de liberação e faz upsert dos pagamentos.
-- Re-varre de hoje−3d (captura a virada pending→released) até hoje+p_dias.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mp_fill_recebiveis(
  p_dias int default 120,
  p_max_paginas int default 300
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_tok      text;
  v_lim      int := 100;
  v_off      int := 0;
  v_total    int := null;
  v_paginas  int := 0;
  v_lidos    int := 0;
  v_st       int;
  v_body     text;
  v_res      jsonb;
  v_x        jsonb;
  v_ini      timestamptz := clock_timestamp();
  v_erro     text := null;
  v_url      text;
begin
  -- Um só ingestor por vez (o diário e uma execução manual não podem se cruzar).
  if not pg_try_advisory_lock(hashtext('mp_fill_recebiveis')) then
    return jsonb_build_object('ok', false, 'mensagem', 'já existe uma ingestão rodando');
  end if;

  select (public.ml_get_state()).access_token into v_tok;
  if v_tok is null then
    perform pg_advisory_unlock(hashtext('mp_fill_recebiveis'));
    insert into ml_cron_log(job, sucesso, mensagem)
      values ('mp_recebiveis', false, 'sem access_token do ML (ml_get_state vazio)');
    return jsonb_build_object('ok', false, 'mensagem', 'sem access_token');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000');

  loop
    v_url := 'https://api.mercadopago.com/v1/payments/search'
          || '?sort=money_release_date&criteria=asc&range=money_release_date'
          || '&begin_date=NOW-3DAYS&end_date=NOW%2B' || p_dias || 'DAYS'
          || '&status=approved&limit=' || v_lim || '&offset=' || v_off;

    begin
      select r.status, r.content into v_st, v_body
      from extensions.http((
        'GET', v_url,
        ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_tok)],
        NULL, NULL
      )::extensions.http_request) r;
    exception when others then
      v_erro := 'HTTP falhou no offset ' || v_off || ': ' || sqlerrm;
      exit;
    end;

    if v_st <> 200 then
      v_erro := 'HTTP ' || v_st || ' no offset ' || v_off;
      exit;
    end if;

    v_res := v_body::jsonb;
    if v_total is null then
      v_total := coalesce((v_res->'paging'->>'total')::int, 0);
    end if;

    for v_x in select * from jsonb_array_elements(coalesce(v_res->'results', '[]'::jsonb)) loop
      insert into mp_pagamentos as m (
        payment_id, order_id, status, status_detail, release_status, release_date,
        date_approved, date_created, valor_bruto, valor_liquido, valor_estornado,
        operation_type, charges, atualizado_em
      )
      values (
        (v_x->>'id')::bigint,
        nullif(v_x->'order'->>'id', ''),
        v_x->>'status',
        v_x->>'status_detail',
        v_x->>'money_release_status',
        nullif(v_x->>'money_release_date','')::timestamptz,
        nullif(v_x->>'date_approved','')::timestamptz,
        nullif(v_x->>'date_created','')::timestamptz,
        nullif(v_x->>'transaction_amount','')::numeric,
        nullif(v_x->'transaction_details'->>'net_received_amount','')::numeric,
        coalesce(nullif(v_x->>'transaction_amount_refunded','')::numeric, 0),
        v_x->>'operation_type',
        v_x->'charges_details',
        now()
      )
      on conflict (payment_id) do update set
        order_id        = excluded.order_id,
        status          = excluded.status,
        status_detail   = excluded.status_detail,
        release_status  = excluded.release_status,
        release_date    = excluded.release_date,
        date_approved   = excluded.date_approved,
        valor_bruto     = excluded.valor_bruto,
        valor_liquido   = excluded.valor_liquido,
        valor_estornado = excluded.valor_estornado,
        charges         = excluded.charges,
        atualizado_em   = now();
      v_lidos := v_lidos + 1;
    end loop;

    v_paginas := v_paginas + 1;
    v_off := v_off + v_lim;
    exit when v_off >= v_total or v_paginas >= p_max_paginas
           or jsonb_array_length(coalesce(v_res->'results','[]'::jsonb)) = 0;
  end loop;

  perform pg_advisory_unlock(hashtext('mp_fill_recebiveis'));

  insert into ml_cron_log(job, sucesso, http_status, pedidos, duracao_ms, mensagem, resposta)
  values (
    'mp_recebiveis',
    v_erro is null,
    v_st,
    v_lidos,
    (extract(epoch from (clock_timestamp() - v_ini)) * 1000)::int,
    coalesce(v_erro, 'ok — ' || v_lidos || ' de ' || coalesce(v_total, 0) || ' pagamentos em ' || v_paginas || ' páginas'),
    jsonb_build_object('total_api', v_total, 'lidos', v_lidos, 'paginas', v_paginas, 'dias', p_dias)
  );

  return jsonb_build_object(
    'ok', v_erro is null,
    'lidos', v_lidos,
    'total_api', v_total,
    'paginas', v_paginas,
    'mensagem', coalesce(v_erro, 'ok')
  );
end;
$function$;

comment on function mp_fill_recebiveis(int, int) is
  'Ingere os pagamentos do MP na janela de liberação [hoje−3d, hoje+p_dias] (upsert por payment_id). '
  'Usa o access_token do Mercado Livre (ml_get_state) — o MP não tem credencial própria.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Leitura: cronograma de recebíveis por dia (consumido por getRecebiveis no app).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function mp_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with hoje as (
    select (now() at time zone 'America/Sao_Paulo')::date as d
  ),
  pend as (
    select
      (p.release_date at time zone 'America/Sao_Paulo')::date as dia,
      p.valor_liquido,
      p.valor_estornado
    from mp_pagamentos p, hoje h
    where p.status = 'approved'
      and p.release_status = 'pending'
      and (p.release_date at time zone 'America/Sao_Paulo')::date >= h.d
  ),
  por_dia as (
    select dia, round(sum(greatest(coalesce(valor_liquido,0) - valor_estornado, 0)), 2) as valor
    from pend
    where valor_liquido is not null
    group by dia
  )
  select jsonb_build_object(
    'referencia',    (select d from hoje),
    'total',         coalesce((select sum(valor) from por_dia), 0),
    'pagamentos',    (select count(*) from pend),
    -- Cobertura honesta: pagamento sem net_received_amount na API não é estimado,
    -- fica de fora do total e é contado aqui.
    'sem_liquido',   (select count(*) from pend where valor_liquido is null),
    'atualizado_em', (select max(atualizado_em) from mp_pagamentos),
    'dias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', dia, 'valor', valor) order by dia) from por_dia),
      '[]'::jsonb
    )
  );
$function$;

comment on function mp_recebiveis() is
  'Cronograma de recebíveis do Mercado Pago: total e valor por dia de liberação (líquido real, sem estimativa).';

revoke all on function mp_fill_recebiveis(int, int) from public, anon, authenticated;
revoke all on function mp_recebiveis() from public, anon, authenticated;
grant execute on function mp_fill_recebiveis(int, int) to service_role;
grant execute on function mp_recebiveis() to service_role;

alter table mp_pagamentos enable row level security;
