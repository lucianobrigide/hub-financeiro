-- ============================================================
-- Shopee DIFAL (ICMS-DIFAL interestadual) — cobrado na CARTEIRA, não no escrow:
--   /api/v2/payment/get_wallet_transaction_list (ADJUSTMENT_CENTER_DEDUCT)
--   2 variantes de reason: "Valor referente ao ICMS para Uf Destino (Difal) gerado no
--   pedido..." (por pedido, sistemático) e "Débito por diferencial de alíquota do ICMS
--   (DIFAL) ... durante fiscalização..." (esporádico).
--
-- NATUREZA: régua = create_time da transação da carteira (dia da cobrança), mês-calendário
-- — igual ao CDIFAL do ML. Amount vem negativo (MONEY_OUT); a dedução do card é o módulo.
-- Junho/2026: 7 cobranças = R$ 171,09 (dedup por transaction_id). API caps: 15 dias/chamada,
-- paginação page_no/page_size(=100). IP 56.126.53.22, HMAC. Achado via busca na carteira
-- (o escrow por pedido NÃO tem DIFAL — todos os campos de imposto = 0).
-- ============================================================

create table if not exists public.shopee_difal (
  id            text primary key,           -- transaction_id (ou hash fallback)
  transaction_id bigint,
  create_time   timestamptz,
  create_date   date,                        -- dia da cobrança (BRT)
  amount        numeric(14,2),               -- valor bruto da carteira (negativo)
  order_sn      text,                        -- pedido referenciado no motivo (quando houver)
  reason        text,
  atualizado_em timestamptz not null default now()
);
alter table public.shopee_difal enable row level security;
create index if not exists shopee_difal_create_date_idx on public.shopee_difal (create_date);

-- Scan da carteira num range, filtra reason DIFAL, upsert idempotente. Janelas de 15 dias.
create or replace function public.shopee_fill_difal(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql security definer
set search_path to 'public','extensions'
set statement_timeout to '300s'
as $$
declare
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_resp jsonb; v_list jsonb; v_t jsonb;
  v_wstart timestamptz; v_wend timestamptz;
  v_page int; v_pc int; v_guard int;
  v_cnt int := 0; v_scanned int := 0; v_id text; v_amt numeric;
begin
  select decrypted_secret into v_pid  from vault.decrypted_secrets where name='shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name='shopee_partner_key';
  select access_token, shop_id into v_access, v_shop_id from shopee_oauth_state where id=1;
  if v_pid is null or v_pkey is null or v_access is null then
    return jsonb_build_object('error','missing_credentials');
  end if;
  if (select expires_at from shopee_oauth_state where id=1) < clock_timestamp() + interval '10 minutes' then
    perform shopee_refresh_token(true);
    select access_token into v_access from shopee_oauth_state where id=1;
  end if;

  v_wstart := p_from;
  while v_wstart < p_to loop
    v_wend := least(v_wstart + interval '14 days 23 hours', p_to);
    v_page := 0; v_guard := 0;
    loop
      v_guard := v_guard + 1; if v_guard > 60 then exit; end if;
      v_resp := _sp_api_get('/api/v2/payment/get_wallet_transaction_list',
        'create_time_from='||extract(epoch from v_wstart)::bigint
        ||'&create_time_to='||extract(epoch from v_wend)::bigint
        ||'&page_no='||v_page||'&page_size=100',
        v_pid, v_pkey, v_access, v_shop_id);
      v_list := v_resp->'response'->'transaction_list';
      if v_list is null or jsonb_array_length(v_list)=0 then exit; end if;
      v_pc := jsonb_array_length(v_list);
      v_scanned := v_scanned + v_pc;
      for v_t in select value from jsonb_array_elements(v_list) loop
        if (v_t->>'reason') ilike '%DIFAL%' or (v_t->>'reason') ilike '%diferencial de al%' then
          v_amt := (v_t->>'amount')::numeric;
          v_id := coalesce(nullif(v_t->>'transaction_id',''),
                           md5((v_t->>'create_time')||'|'||v_amt||'|'||coalesce(v_t->>'reason','')));
          insert into public.shopee_difal (id, transaction_id, create_time, create_date, amount, order_sn, reason)
          values (v_id, nullif(v_t->>'transaction_id','')::bigint,
                  to_timestamp((v_t->>'create_time')::bigint),
                  to_timestamp((v_t->>'create_time')::bigint)::date,
                  v_amt, nullif(v_t->>'order_sn',''), v_t->>'reason')
          on conflict (id) do update set
            amount=excluded.amount, create_date=excluded.create_date,
            order_sn=excluded.order_sn, reason=excluded.reason, atualizado_em=now();
          v_cnt := v_cnt + 1;
        end if;
      end loop;
      if v_pc < 100 then exit; end if;
      v_page := v_page + 1;
    end loop;
    v_wstart := v_wend + interval '1 second';
  end loop;

  return jsonb_build_object('difal_cobrancas', v_cnt, 'transacoes_varridas', v_scanned);
end $$;

-- RPC do card: soma do DIFAL no mês-calendário (positivo = módulo do débito).
create or replace function public.shopee_difal(p_month text)
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'difal_total_mes',
    coalesce((
      select round(-sum(amount), 2)
      from public.shopee_difal
      where to_char(create_date, 'YYYY-MM') = p_month
        and create_date < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$$;

revoke all on function public.shopee_fill_difal(timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.shopee_difal(text)                          from public, anon, authenticated;
grant execute on function public.shopee_fill_difal(timestamptz, timestamptz) to service_role;
grant execute on function public.shopee_difal(text)                          to service_role;
