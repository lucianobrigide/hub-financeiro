-- ============================================================
-- Shopee ADS (CPC) — gasto de mídia, via API de Ads da Shopee:
--   GET /api/v2/ads/get_all_cpc_ads_daily_performance?start_date=DD-MM-YYYY&end_date=DD-MM-YYYY
--   -> array por dia com { date, expense, clicks, impression, broad_gmv, ... }
--
-- CORREÇÃO: a nota "ADS pendente — precisa escopo Ads no Partner Center" estava ERRADA.
-- O escopo de Ads JÁ existe no token OAuth atual (testado ao vivo, HTTP 200 com dado).
--
-- NATUREZA: régua = data do gasto (competência diária, mês-calendário). Campo `expense`
-- do CPC diário. SEPARADO do escrow (o escrow tem comissão/frete/serviço/AMS, NÃO ads) —
-- zero dupla contagem. Junho/2026: R$ 48.368,82 (validado no painel). ACHADO: a Shopee
-- fica NEGATIVA em junho depois da mídia (M.C. −R$ 21.409,46).
-- Chamadas HTTP saem do PG (IP 56.126.53.22 whitelistado) via _sp_api_get (HMAC-SHA256).
-- ============================================================

create table if not exists public.shopee_ads_diario (
  data          date primary key,          -- dia do gasto (BRT)
  expense       numeric(14,2) not null,     -- gasto CPC do dia (R$)
  clicks        integer,                    -- cliques (referência)
  impression    bigint,                     -- impressões (referência)
  broad_gmv     numeric(14,2),              -- GMV amplo atribuído (referência)
  atualizado_em timestamptz not null default now()
);
alter table public.shopee_ads_diario enable row level security;

-- Ingest do gasto diário de Ads num range (idempotente por data). Refaz token se stale.
create or replace function public.shopee_fill_ads(p_start date, p_end date)
returns jsonb
language plpgsql security definer
set search_path to 'public','extensions'
as $$
declare
  v_pid text; v_pkey text; v_access text; v_shop_id bigint;
  v_resp jsonb; v_arr jsonb; v_r jsonb;
  v_days int := 0; v_sum numeric := 0;
begin
  select decrypted_secret into v_pid  from vault.decrypted_secrets where name = 'shopee_partner_id';
  select decrypted_secret into v_pkey from vault.decrypted_secrets where name = 'shopee_partner_key';
  select access_token, shop_id into v_access, v_shop_id from shopee_oauth_state where id = 1;

  if v_pid is null or v_pkey is null or v_access is null then
    return jsonb_build_object('error', 'missing_credentials');
  end if;

  if (select expires_at from shopee_oauth_state where id = 1) < clock_timestamp() + interval '10 minutes' then
    perform shopee_refresh_token(true);
    select access_token into v_access from shopee_oauth_state where id = 1;
  end if;

  v_resp := _sp_api_get(
    '/api/v2/ads/get_all_cpc_ads_daily_performance',
    'start_date=' || to_char(p_start, 'DD-MM-YYYY') || '&end_date=' || to_char(p_end, 'DD-MM-YYYY'),
    v_pid, v_pkey, v_access, v_shop_id);

  if v_resp->>'error' is not null and v_resp->>'error' <> '' then
    return jsonb_build_object('error', v_resp->>'error', 'message', v_resp->>'message');
  end if;

  v_arr := v_resp->'response';
  if jsonb_typeof(v_arr) = 'array' then
    for v_r in select value from jsonb_array_elements(v_arr) loop
      insert into public.shopee_ads_diario (data, expense, clicks, impression, broad_gmv)
      values (
        to_date(v_r->>'date', 'DD-MM-YYYY'),
        coalesce((v_r->>'expense')::numeric, 0),
        coalesce((v_r->>'clicks')::int, 0),
        coalesce((v_r->>'impression')::bigint, 0),
        coalesce((v_r->>'broad_gmv')::numeric, 0)
      )
      on conflict (data) do update set
        expense = excluded.expense, clicks = excluded.clicks,
        impression = excluded.impression, broad_gmv = excluded.broad_gmv, atualizado_em = now();
      v_days := v_days + 1;
      v_sum := v_sum + coalesce((v_r->>'expense')::numeric, 0);
    end loop;
  end if;

  return jsonb_build_object('dias', v_days, 'expense_total', round(v_sum, 2), 'de', p_start, 'ate', p_end);
end $$;

-- RPC do card: soma o expense diário no mês-calendário (guarda o dia corrente).
create or replace function public.shopee_ads(p_month text)
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'ads_total_mes',
    coalesce((
      select round(sum(expense), 2)
      from public.shopee_ads_diario
      where to_char(data, 'YYYY-MM') = p_month
        and data < (now() at time zone 'America/Sao_Paulo')::date
    ), 0)
  );
$$;

revoke all on function public.shopee_fill_ads(date, date) from public, anon, authenticated;
revoke all on function public.shopee_ads(text)            from public, anon, authenticated;
grant execute on function public.shopee_fill_ads(date, date) to service_role;
grant execute on function public.shopee_ads(text)            to service_role;
