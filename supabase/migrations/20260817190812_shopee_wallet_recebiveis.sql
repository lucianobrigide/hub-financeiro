-- ============================================================================
-- Shopee — recebíveis (F.C. Projetado) · 17/08/2026
-- ============================================================================
-- ⚠️ A Shopee informa QUANTO, não QUANDO. get_escrow_detail traz ~90 campos de
-- valor e NENHUMA data de liberação (verificado 17/08/2026 no pedido
-- 260817JF32WA8M: order_income não tem release/payout time). A carteira
-- (get_wallet_transaction_list) só registra o que JÁ caiu.
-- Portanto o card da Shopee mostra total a receber SEM cronograma. Estimar a
-- data pelo lag histórico seria inventar — REGRA DURA.
--
-- Régua: a receber = Σ escrow (adjusted) dos pedidos não cancelados que ainda
-- NÃO têm crédito de renda na carteira (ESCROW_VERIFIED_ADD), restrito à janela
-- coberta pela ingestão da carteira (pedido anterior a ela não é "não pago",
-- é desconhecido — fica fora e é reportado como cobertura).
-- Saldo disponível = current_balance da transação mais recente da carteira.
--
-- ⚠️ Esta régua é a v1: a 20260817191510 corrige o furo das devoluções.
--
-- API: /api/v2/payment/get_wallet_transaction_list — janela máx. **14 dias**
-- (15 devolve wallet.time_invalid "time period too large"), paginado por
-- page_no/page_size com flag `more`.

create table if not exists shopee_wallet (
  transaction_id   bigint primary key,
  order_sn         text,
  transaction_type text,
  money_flow       text,
  status           text,
  amount           numeric(14,2),
  create_time      timestamptz,
  current_balance  numeric(14,2),
  descricao        text,
  inserted_at      timestamptz not null default now()
);

comment on table shopee_wallet is
  'Transações da carteira Shopee (o dinheiro que JÁ caiu). Usada para saber qual escrow ainda está a receber e qual é o saldo disponível.';

create index if not exists shopee_wallet_order_idx on shopee_wallet (order_sn) where order_sn is not null and order_sn <> '';
create index if not exists shopee_wallet_time_idx on shopee_wallet (create_time desc);

create or replace function shopee_fill_wallet(p_dias int default 90)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_ini timestamptz := clock_timestamp();
  v_de bigint; v_ate bigint; v_janela_fim timestamptz; v_janela_ini timestamptz;
  v_page int; v_resp jsonb; v_x jsonb; v_more boolean;
  v_lidos int := 0; v_paginas int := 0; v_erro text := null;
begin
  if not pg_try_advisory_lock(hashtext('shopee_fill_wallet')) then
    return jsonb_build_object('ok', false, 'mensagem', 'já existe uma ingestão rodando');
  end if;

  select decrypted_secret into v_pid  from vault.decrypted_secrets where name='shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name='shopee_partner_key';
  select access_token, shop_id into v_access, v_shop_id from shopee_oauth_state where id=1;
  if v_pid is null or v_pkey is null or v_access is null then
    perform pg_advisory_unlock(hashtext('shopee_fill_wallet'));
    return jsonb_build_object('ok', false, 'mensagem', 'sem credenciais da Shopee');
  end if;
  if (select expires_at from shopee_oauth_state where id=1) < clock_timestamp() + interval '10 minutes' then
    perform shopee_refresh_token(true);
    select access_token into v_access from shopee_oauth_state where id=1;
  end if;

  -- Janelas de 13 dias (cap da API é 14) do mais recente para trás.
  v_janela_fim := clock_timestamp();
  while v_janela_fim > clock_timestamp() - (p_dias || ' days')::interval loop
    v_janela_ini := greatest(v_janela_fim - interval '13 days',
                             clock_timestamp() - (p_dias || ' days')::interval);
    v_de  := extract(epoch from v_janela_ini)::bigint;
    v_ate := extract(epoch from v_janela_fim)::bigint;
    v_page := 0;

    loop
      begin
        v_resp := _sp_api_get('/api/v2/payment/get_wallet_transaction_list',
          'page_no=' || v_page || '&page_size=100'
          || '&create_time_from=' || v_de || '&create_time_to=' || v_ate,
          v_pid, v_pkey, v_access, v_shop_id);
      exception when others then
        v_erro := 'HTTP falhou (janela ' || v_janela_ini::date || ', page ' || v_page || '): ' || sqlerrm;
        exit;
      end;

      if coalesce(v_resp->>'error','') <> '' then
        v_erro := 'API: ' || (v_resp->>'error') || ' — ' || coalesce(v_resp->>'message','');
        exit;
      end if;

      for v_x in select * from jsonb_array_elements(coalesce(v_resp->'response'->'transaction_list','[]'::jsonb)) loop
        insert into shopee_wallet as w (
          transaction_id, order_sn, transaction_type, money_flow, status,
          amount, create_time, current_balance, descricao
        ) values (
          (v_x->>'transaction_id')::bigint,
          nullif(v_x->>'order_sn',''),
          v_x->>'transaction_type',
          v_x->>'money_flow',
          v_x->>'status',
          nullif(v_x->>'amount','')::numeric,
          to_timestamp((v_x->>'create_time')::bigint),
          nullif(v_x->>'current_balance','')::numeric,
          v_x->>'description'
        )
        on conflict (transaction_id) do update set
          status          = excluded.status,
          amount          = excluded.amount,
          current_balance = excluded.current_balance,
          order_sn        = excluded.order_sn;
        v_lidos := v_lidos + 1;
      end loop;

      v_paginas := v_paginas + 1;
      v_more := coalesce((v_resp->'response'->>'more')::boolean, false);
      exit when not v_more or v_paginas > 400;
      v_page := v_page + 1;
    end loop;

    exit when v_erro is not null;
    v_janela_fim := v_janela_ini;
  end loop;

  perform pg_advisory_unlock(hashtext('shopee_fill_wallet'));

  insert into ml_cron_log(job, sucesso, pedidos, duracao_ms, mensagem, resposta)
  values ('shopee_wallet', v_erro is null, v_lidos,
          (extract(epoch from (clock_timestamp()-v_ini))*1000)::int,
          coalesce(v_erro, 'ok — ' || v_lidos || ' transações em ' || v_paginas || ' páginas'),
          jsonb_build_object('lidos', v_lidos, 'paginas', v_paginas, 'dias', p_dias));

  return jsonb_build_object('ok', v_erro is null, 'lidos', v_lidos,
                            'paginas', v_paginas, 'mensagem', coalesce(v_erro,'ok'));
end;
$function$;

comment on function shopee_fill_wallet(int) is
  'Ingere as transações da carteira Shopee (janelas de 13 dias — o cap da API é 14). Base do "já caiu" e do saldo disponível.';

create or replace function shopee_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cobertura as (
    select min(create_time) as desde, max(create_time) as ate from shopee_wallet
  ),
  saldo as (
    select current_balance from shopee_wallet order by create_time desc, transaction_id desc limit 1
  ),
  pagos as (
    select distinct order_sn from shopee_wallet
    where transaction_type = 'ESCROW_VERIFIED_ADD' and order_sn is not null and order_sn <> ''
  ),
  pend as (
    select p.order_sn, coalesce(p.escrow_adjusted, p.escrow_amount) as valor
    from shopee_pedidos p, cobertura c
    where p.order_status not in ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')
      and coalesce(p.escrow_adjusted, p.escrow_amount) is not null
      and p.create_time >= c.desde              -- fora da janela da carteira = desconhecido, não "a receber"
      and not exists (select 1 from pagos g where g.order_sn = p.order_sn)
  )
  select jsonb_build_object(
    'referencia',    (now() at time zone 'America/Sao_Paulo')::date,
    'total',         coalesce((select round(sum(valor),2) from pend), 0),
    'pedidos',       (select count(*) from pend),
    'disponivel',    (select current_balance from saldo),
    'cobertura_de',  (select desde::date from cobertura),
    'cobertura_ate', (select ate::date from cobertura),
    'atualizado_em', (select max(inserted_at) from shopee_wallet),
    -- A Shopee não publica data de liberação: sem cronograma, por decisão de régua.
    'dias', '[]'::jsonb
  );
$function$;

comment on function shopee_recebiveis() is
  'Recebíveis Shopee: total de escrow ainda não creditado na carteira + saldo disponível. SEM cronograma — a API não informa data de liberação.';

revoke all on function shopee_fill_wallet(int) from public, anon, authenticated;
revoke all on function shopee_recebiveis() from public, anon, authenticated;
grant execute on function shopee_fill_wallet(int) to service_role;
grant execute on function shopee_recebiveis() to service_role;

alter table shopee_wallet enable row level security;
