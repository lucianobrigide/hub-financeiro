-- ═══════════════════════════════════════════════════════════════════════════
-- TikTok GMV Max (Business/Marketing API) — custódia + ingestão do gasto diário
-- PRODUTO × LIVE em tt_ads_diario. Pedido do Luciano 25/08/2026: "no hub do
-- TikTok entre os gastos com GMV Max de live e de produtos".
--
-- Auth: developer app no portal TikTok for Business (business-api.tiktok.com),
-- SEPARADA do app da Shop API ("Hub Financeiro Essenza Inhouse"). O token é de
-- LONGA DURAÇÃO e NÃO EXPIRA (sem cron keepalive — docs "Obtain a long-term
-- access token"). A troca do auth_code acontece DENTRO do Postgres
-- (ttads_exchange_code); a Edge ttads-oauth-callback só repassa o code.
--
-- Gasto: GET /open_api/v1.3/gmv_max/report/get/ (SÍNCRONO, sem fila tipo Amazon),
-- dimensions=["stat_time_day"] (janela máx. 30d), metrics cost/net_cost/orders/
-- gross_revenue, filtro gmv_max_promotion_types = PRODUCT | LIVE (2 chamadas).
-- Datas no fuso da conta de anúncios (BR = America/Sao_Paulo).
--
-- Anti-dupla-contagem: JÁ EMBUTIDO em tt_deducoes_projetado desde 20260812120001
-- (mês com linha em tt_ads_diario usa SÓ o custo real daqui e ignora as chaves
-- gmv_max do settlement). Esta migration só acrescenta a quebra Produto × LIVE.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) tt_ads_diario ganha a dimensão tipo (PRODUCT|LIVE) + net_cost.
--    Tabela está VAZIA (verificado 25/08/2026) — troca de PK é segura.
--    Leitores (tt_deducoes_projetado, dre_diario_canais) fazem sum(cost) — seguem
--    corretos com múltiplas linhas por dia.
alter table public.tt_ads_diario add column if not exists tipo text not null default 'PRODUCT';
alter table public.tt_ads_diario add column if not exists net_cost numeric;
alter table public.tt_ads_diario drop constraint if exists tt_ads_diario_pkey;
alter table public.tt_ads_diario add primary key (data, tipo);
alter table public.tt_ads_diario alter column tipo drop default;
alter table public.tt_ads_diario add constraint tt_ads_diario_tipo_chk check (tipo in ('PRODUCT','LIVE'));
comment on table public.tt_ads_diario is
'Gasto diario TikTok GMV Max (Business API /gmv_max/report/get/), 1 linha por (data, tipo PRODUCT|LIVE). cost = custo bruto do painel; net_cost = custo liquido de creditos/cupons (guardado para comparacao — se divergirem, decisao do Luciano sobre qual entra no DRE). Enquanto vazio, o DRE usa as chaves gmv_max do settlement; quando preenchido, o mes usa o custo real daqui e o settlement de ads e IGNORADO (anti-dupla-contagem em tt_deducoes_projetado).';

-- 2) Estado não-sensível (singleton id=1) + segredos no Vault.
create table if not exists public.ttads_oauth_state (
  id             int primary key check (id = 1),
  advertiser_id  text,
  advertiser_ids jsonb,
  store_id       text,
  store_name     text,
  scope          jsonb,
  authorized_at  timestamptz,
  updated_at     timestamptz not null default now()
);
comment on table public.ttads_oauth_state is
'Estado nao-sensivel da conexao TikTok Business API (GMV Max). O access_token (longa duracao, nao expira) vive SO no Vault (ttads_access_token), junto com ttads_app_id/ttads_app_secret. Linha unica id=1.';
alter table public.ttads_oauth_state enable row level security;
insert into public.ttads_oauth_state (id) values (1) on conflict (id) do nothing;

do $$
declare s text;
begin
  foreach s in array array['ttads_app_id','ttads_app_secret','ttads_access_token']
  loop
    if not exists (select 1 from vault.secrets where name = s) then
      perform vault.create_secret('__SET_ME__', s, 'TikTok Business API (GMV Max) — semeado fora de migration');
    end if;
  end loop;
end $$;

-- 3) Descoberta do TikTok Shop (store_id) autorizado para GMV Max.
--    Chamada após a troca do code (e re-chamável a qualquer momento).
create or replace function public.ttads_descobrir_store()
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_tok text; v_adv text;
  v_status int; v_raw text; v_body jsonb; v_store jsonb; v_n int;
begin
  select decrypted_secret into v_tok from vault.decrypted_secrets where name = 'ttads_access_token';
  select advertiser_id into v_adv from public.ttads_oauth_state where id = 1;
  if v_tok is null or v_tok = '__SET_ME__' or v_adv is null then
    return jsonb_build_object('ok', false, 'error', 'sem_token_ou_advertiser');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'GET',
    'https://business-api.tiktok.com/open_api/v1.3/gmv_max/store/list/?advertiser_id=' || extensions.urlencode(v_adv),
    array[ extensions.http_header('Access-Token', v_tok) ],
    null, null
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw,''),1) = '{' then v_raw::jsonb else null end;
  if v_status <> 200 or coalesce((v_body->>'code')::int, -1) <> 0 then
    return jsonb_build_object('ok', false, 'error', 'store_list_falhou',
      'http_status', v_status, 'detail', left(coalesce(v_raw,'sem corpo'), 400));
  end if;

  select count(*) into v_n from jsonb_array_elements(coalesce(v_body->'data'->'store_list','[]'::jsonb));
  -- preferir loja com is_gmv_max_available = true; a operação tem UMA loja
  select s into v_store
  from jsonb_array_elements(coalesce(v_body->'data'->'store_list','[]'::jsonb)) s
  order by (s->>'is_gmv_max_available')::boolean desc nulls last
  limit 1;
  if v_store is null then
    return jsonb_build_object('ok', false, 'error', 'nenhuma_loja', 'total', v_n);
  end if;

  update public.ttads_oauth_state
     set store_id = v_store->>'store_id', store_name = v_store->>'store_name', updated_at = now()
   where id = 1;
  return jsonb_build_object('ok', true, 'store_id', v_store->>'store_id',
    'store_name', v_store->>'store_name',
    'gmv_max_disponivel', (v_store->>'is_gmv_max_available')::boolean, 'total_lojas', v_n);
end $$;

-- 4) Troca do auth_code (uso único, expira em 1h) pelo token de longa duração.
--    Chamada UMA vez pela Edge ttads-oauth-callback. TikTok devolve HTTP 200 com
--    code<>0 em erro — o teste é o code do corpo, não só o status.
create or replace function public.ttads_exchange_code(p_auth_code text)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_app text; v_sec text; v_tok_id uuid;
  v_status int; v_raw text; v_body jsonb; v_data jsonb;
  v_advs jsonb; v_adv text; v_store jsonb;
begin
  perform pg_advisory_xact_lock(421982801);

  if p_auth_code is null or p_auth_code = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_code');
  end if;

  select decrypted_secret into v_app from vault.decrypted_secrets where name = 'ttads_app_id';
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'ttads_app_secret';
  select id into v_tok_id from vault.secrets where name = 'ttads_access_token';
  if v_app is null or v_app = '__SET_ME__' or v_sec is null or v_sec = '__SET_ME__' then
    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('ttads_brigide', null, false, 'exchange_code: credenciais ttads_* ausentes no Vault');
    return jsonb_build_object('ok', false, 'error', 'missing_credentials');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select r.status, r.content into v_status, v_raw
  from extensions.http((
    'POST', 'https://business-api.tiktok.com/open_api/v1.3/oauth2/access_token/',
    array[ extensions.http_header('Accept', 'application/json') ],
    'application/json',
    jsonb_build_object('app_id', v_app, 'secret', v_sec, 'auth_code', p_auth_code)::text
  )::extensions.http_request) as r;

  v_body := case when left(coalesce(v_raw,''),1) = '{' then v_raw::jsonb else null end;
  v_data := v_body->'data';

  if v_status = 200 and coalesce((v_body->>'code')::int, -1) = 0 and (v_data ? 'access_token') then
    -- 1) token no Vault (longa duração, não expira)
    perform vault.update_secret(v_tok_id, v_data->>'access_token');

    -- 2) estado não-sensível; advertiser auto-selecionado quando a conta é única
    v_advs := coalesce(v_data->'advertiser_ids', '[]'::jsonb);
    v_adv  := case when jsonb_array_length(v_advs) = 1 then v_advs->>0 else null end;
    update public.ttads_oauth_state
       set advertiser_ids = v_advs, advertiser_id = coalesce(v_adv, advertiser_id),
           scope = v_data->'scope', authorized_at = now(), updated_at = now()
     where id = 1;

    insert into public.oauth_refresh_log(conta, http_status, success, message)
    values ('ttads_brigide', v_status, true,
            format('ok (auth_code trocado; %s ad account(s); advertiser_id %s)',
                   jsonb_array_length(v_advs), coalesce(v_adv, 'A DEFINIR MANUALMENTE')));

    -- 3) descoberta do store (best-effort — falha não desfaz a autorização)
    if v_adv is not null then
      begin
        v_store := public.ttads_descobrir_store();
      exception when others then
        v_store := jsonb_build_object('ok', false, 'error', sqlerrm);
      end;
    end if;

    return jsonb_build_object('ok', true, 'advertiser_id', v_adv,
      'advertiser_ids', v_advs, 'store', v_store);
  end if;

  insert into public.oauth_refresh_log(conta, http_status, success, message)
  values ('ttads_brigide', v_status, false,
          'exchange_code FALHOU: ' || left(coalesce(v_raw,'sem corpo'), 400));
  return jsonb_build_object('ok', false, 'error', 'exchange_failed',
    'http_status', v_status, 'detail', left(coalesce(v_raw,'sem corpo'), 400));
end $$;

-- 5) Ingestão do gasto GMV Max por dia × tipo (PRODUCT, LIVE), janela ≤ 30d.
--    Snapshot honesto: busca TODAS as páginas do tipo primeiro; só então
--    delete+insert da janela na MESMA transação (falha no meio não apaga nada).
create or replace function public.ttads_fill_gastos(p_de date, p_ate date)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_tok text; v_adv text; v_store text;
  v_tipo text; v_page int; v_total_page int;
  v_status int; v_raw text; v_body jsonb;
  v_rows jsonb; v_url text;
  v_ins int; v_out jsonb := '{}'::jsonb; v_erros text := '';
begin
  if p_ate - p_de > 29 then
    return jsonb_build_object('ok', false, 'error', 'janela_maior_que_30d');
  end if;

  select decrypted_secret into v_tok from vault.decrypted_secrets where name = 'ttads_access_token';
  select advertiser_id, store_id into v_adv, v_store from public.ttads_oauth_state where id = 1;
  if v_tok is null or v_tok = '__SET_ME__' then
    return jsonb_build_object('ok', false, 'error', 'sem_token');
  end if;
  if v_adv is null or v_store is null then
    return jsonb_build_object('ok', false, 'error', 'sem_advertiser_ou_store');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  foreach v_tipo in array array['PRODUCT','LIVE'] loop
    v_rows := '[]'::jsonb; v_page := 1; v_total_page := 1;

    loop
      v_url := 'https://business-api.tiktok.com/open_api/v1.3/gmv_max/report/get/'
        || '?advertiser_id=' || extensions.urlencode(v_adv)
        || '&store_ids='     || extensions.urlencode(jsonb_build_array(v_store)::text)
        || '&dimensions='    || extensions.urlencode('["stat_time_day"]')
        || '&metrics='       || extensions.urlencode('["cost","net_cost","orders","gross_revenue"]')
        || '&start_date=' || to_char(p_de,  'YYYY-MM-DD')
        || '&end_date='   || to_char(p_ate, 'YYYY-MM-DD')
        || '&filtering='  || extensions.urlencode(jsonb_build_object('gmv_max_promotion_types', jsonb_build_array(v_tipo))::text)
        || '&page=' || v_page || '&page_size=200';

      select r.status, r.content into v_status, v_raw
      from extensions.http((
        'GET', v_url,
        array[ extensions.http_header('Access-Token', v_tok) ],
        null, null
      )::extensions.http_request) as r;

      v_body := case when left(coalesce(v_raw,''),1) = '{' then v_raw::jsonb else null end;
      if v_status <> 200 or coalesce((v_body->>'code')::int, -1) <> 0 then
        v_erros := v_erros || format('[%s p%s] HTTP %s: %s; ', v_tipo, v_page, v_status,
                                     left(coalesce(v_body->>'message', v_raw, 'sem corpo'), 200));
        v_rows := null;  -- não substituir a janela deste tipo
        exit;
      end if;

      v_rows := v_rows || coalesce(v_body->'data'->'list', '[]'::jsonb);
      v_total_page := coalesce((v_body->'data'->'page_info'->>'total_page')::int, 1);
      exit when v_page >= v_total_page;
      v_page := v_page + 1;
    end loop;

    if v_rows is not null then
      -- snapshot: substitui a janela do tipo (dia que sumir do relatório sai daqui)
      delete from public.tt_ads_diario where tipo = v_tipo and data between p_de and p_ate;
      insert into public.tt_ads_diario (data, tipo, cost, net_cost, orders, gmv, fonte, updated_at)
      select
        left(r->'dimensions'->>'stat_time_day', 10)::date,
        v_tipo,
        coalesce(nullif(r->'metrics'->>'cost','')::numeric, 0),
        nullif(r->'metrics'->>'net_cost','')::numeric,
        nullif(r->'metrics'->>'orders','')::int,
        nullif(r->'metrics'->>'gross_revenue','')::numeric,
        'gmv_max_api', now()
      from jsonb_array_elements(v_rows) r
      where left(r->'dimensions'->>'stat_time_day', 10) ~ '^\d{4}-\d{2}-\d{2}$'
      on conflict (data, tipo) do update
        set cost = excluded.cost, net_cost = excluded.net_cost, orders = excluded.orders,
            gmv = excluded.gmv, fonte = excluded.fonte, updated_at = now();
      get diagnostics v_ins = row_count;
      v_out := v_out || jsonb_build_object(lower(v_tipo),
        jsonb_build_object('dias', v_ins,
          'custo', (select coalesce(sum(cost),0) from public.tt_ads_diario
                    where tipo = v_tipo and data between p_de and p_ate)));
    end if;
  end loop;

  return jsonb_build_object('ok', v_erros = '', 'de', p_de, 'ate', p_ate)
         || v_out
         || case when v_erros <> '' then jsonb_build_object('erros', v_erros) else '{}'::jsonb end;
end $$;

-- 6) Cron diário: re-varre hoje-3..hoje (BRT) — atribuição do GMV Max é 24h,
--    3 dias de folga cobrem consolidação tardia. Estado "aguardando autorização"
--    é PENDENTE honesto (não é falha): loga sucesso=true com a mensagem clara.
create or replace function public.ttads_diario()
returns void language plpgsql security definer
set search_path to 'public','vault'
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_res jsonb; v_err text;
begin
  begin
    v_res := public.ttads_fill_gastos(v_hoje - 3, v_hoje);
  exception when others then
    v_err := SQLERRM;
  end;

  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, pedidos, mensagem)
  values (now(), 'ttads_diario', v_hoje,
          coalesce((v_res->>'ok')::boolean, false) or coalesce(v_res->>'error','') in ('sem_token','sem_advertiser_ou_store'),
          null,
          case
            when v_err is not null then 'ERRO: ' || v_err
            when v_res->>'error' = 'sem_token' then 'aguardando autorização da Business API (token não semeado) — nada a fazer'
            when v_res->>'error' = 'sem_advertiser_ou_store' then 'token ok, mas advertiser_id/store_id não definidos em ttads_oauth_state'
            when (v_res->>'ok')::boolean then format('GMV Max %s..%s: Produto R$ %s (%s dias) · LIVE R$ %s (%s dias)',
              v_res->>'de', v_res->>'ate',
              coalesce(v_res->'product'->>'custo','0'), coalesce(v_res->'product'->>'dias','0'),
              coalesce(v_res->'live'->>'custo','0'),    coalesce(v_res->'live'->>'dias','0'))
            else 'FALHA: ' || coalesce(v_res->>'erros', v_res::text)
          end);
end $$;

revoke all on function public.ttads_descobrir_store() from public, anon, authenticated;
revoke all on function public.ttads_exchange_code(text) from public, anon, authenticated;
revoke all on function public.ttads_fill_gastos(date, date) from public, anon, authenticated;
revoke all on function public.ttads_diario() from public, anon, authenticated;
grant execute on function public.ttads_descobrir_store() to service_role;
grant execute on function public.ttads_exchange_code(text) to service_role;
grant execute on function public.ttads_fill_gastos(date, date) to service_role;
grant execute on function public.ttads_diario() to service_role;

-- 04:10 BRT (07:10 UTC), logo após o tt-diario (04:00 BRT).
select cron.schedule('ttads-diario', '10 7 * * *', $$select public.ttads_diario();$$);

-- 7) Catálogo da página /crons.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';
  if position('ttads-diario' in v_def) > 0 then
    raise notice 'catálogo já tem ttads-diario'; return;
  end if;
  v_row := $r$('ttads-diario','TikTok','diario','Todo dia às 04:10 BRT',
     'Puxa da conta de anúncios do TikTok o gasto diário real com GMV Max, separado entre campanhas de Produto e de LIVE (últimos 4 dias, cobrindo consolidação tardia). Enquanto a Business API não estiver autorizada, o job registra "aguardando autorização" — não é falha.',
     'honesto', 28, null),
    $r$;
  v_new := replace(v_def, '(''ml-semanal'',''Mercado Livre'',''semanal''', v_row || '(''ml-semanal'',''Mercado Livre'',''semanal''');
  if v_new = v_def then raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado'; end if;
  execute v_new;
end
$do$;

-- 8) tt_deducoes_projetado ganha a quebra ads_produto/ads_live (só muda o CTE
--    ads_dia e o jsonb final; toda a lógica de provisão fica intocada —
--    corpo idêntico ao de 20260812120001 fora isso).
create or replace function public.tt_deducoes_projetado(p_month text)
returns jsonb
language sql stable security definer
set search_path to 'public'
as $function$
with tr as (select public.tt_take_rates(60) as r),
ads_dia as (
  select coalesce(sum(cost),0) as custo,
         coalesce(sum(cost) filter (where tipo = 'PRODUCT'),0) as custo_produto,
         coalesce(sum(cost) filter (where tipo = 'LIVE'),0)    as custo_live,
         count(distinct data) as dias
  from tt_ads_diario where to_char(data,'YYYY-MM') = p_month
),
ped as (
  select p.*, coalesce(it.q,1) as itens
  from tt_pedidos p
  left join (select order_id, sum(quantity) q from tt_itens where line_status <> 'CANCELLED' group by 1) it
    using (order_id)
  where to_char(p.create_time at time zone 'America/Sao_Paulo','YYYY-MM') = p_month
    and p.order_status not in ('CANCELLED','UNPAID')
),
real_liq as (
  select
    coalesce(-sum(coalesce((fin_breakdown->>'platform_commission_amount')::numeric,0)),0) as comissao,
    coalesce(-sum(coalesce((fin_breakdown->>'affiliate_commission_amount')::numeric,0)),0) as afiliados,
    coalesce(-sum( coalesce((fin_breakdown->>'affiliate_ads_commission_amount')::numeric,0)
        + coalesce((fin_breakdown->>'gmv_max_ad_fee_amount')::numeric,0)
        + coalesce((fin_breakdown->>'smart_promotion_fee_amount')::numeric,0)
        + coalesce((fin_breakdown->>'tap_shop_ads_commission')::numeric,0)
        + coalesce((fin_breakdown->>'cps_shop_ads_commission_tax_amount')::numeric,0)
        + coalesce((fin_breakdown->>'brand_amplification_program_commission')::numeric,0)
        + coalesce((fin_breakdown->>'brand_campaign_fee')::numeric,0)
        + coalesce((fin_breakdown->>'category_led_campaign_fee_amount')::numeric,0)
        + coalesce((fin_breakdown->>'campaign_period_fee_cfp_amount')::numeric,0)
        + coalesce((fin_breakdown->>'campaign_period_fee_sp_amount')::numeric,0)
        + coalesce((fin_breakdown->>'live_specials_fee_amount')::numeric,0)
        + coalesce((fin_breakdown->>'flash_sales_service_fee_amount')::numeric,0)
        + coalesce((fin_breakdown->>'cofunded_creator_bonus_amount')::numeric,0)
        + coalesce((fin_breakdown->>'cofunded_promotion_service_fee_amount')::numeric,0)
        ),0) as ads,
    coalesce(-sum(coalesce(fin_frete,0)),0) as frete,
    coalesce(-sum(coalesce(fin_fee_tax,0)),0) as fee_tax_total,
    count(*) as pedidos,
    coalesce(sum(coalesce(fin_revenue, payment_total)),0) as receita
  from ped where fin_filled
),
prov as (
  select
    coalesce(sum((tr.r->>'comissao_pct')::numeric * payment_total),0) as comissao,
    coalesce(sum(case when aff_filled then coalesce(aff_commission,0)
                      else (tr.r->>'afiliado_pct')::numeric * payment_total end),0) as afiliados,
    coalesce(sum((tr.r->>'ads_pct')::numeric * payment_total),0) as ads,
    coalesce(sum((tr.r->>'frete_pct')::numeric * payment_total),0) as frete,
    coalesce(sum( (tr.r->>'sfp_pct')::numeric * payment_total
                + (tr.r->>'fee_item')::numeric * itens
                + (tr.r->>'outras_pct')::numeric * payment_total),0) as taxas,
    count(*) as pedidos,
    coalesce(sum(payment_total),0) as receita,
    count(*) filter (where aff_filled) as pedidos_aff_real
  from ped, tr where not fin_filled
),
m as (
  select
    rl.comissao + pv.comissao as comissao,
    rl.afiliados + pv.afiliados as afiliados,
    case when ad.dias > 0 then ad.custo else rl.ads + pv.ads end as ads,
    rl.frete + pv.frete as frete,
    (rl.fee_tax_total - rl.comissao - rl.afiliados - rl.ads) + pv.taxas as taxas,
    rl.pedidos as pedidos_liq, pv.pedidos as pedidos_prov,
    rl.receita as receita_liq, pv.receita as receita_prov,
    pv.pedidos_aff_real,
    ad.dias as ads_dias_reais,
    ad.custo_produto as ads_produto,
    ad.custo_live as ads_live
  from real_liq rl, prov pv, ads_dia ad
)
select jsonb_build_object(
  'comissao',  round(comissao, 2),
  'afiliados', round(afiliados, 2),
  'ads',       round(ads, 2),
  'frete',     round(frete, 2),
  'taxas',     round(taxas, 2),
  'pedidos',   pedidos_liq + pedidos_prov,
  'pedidos_liquidados',  pedidos_liq,
  'pedidos_provisionados', pedidos_prov,
  'pedidos_afiliado_real', pedidos_aff_real,
  'pct_liquidado', coalesce(round(receita_liq / nullif(receita_liq + receita_prov, 0) * 100, 1), 0),
  'ads_fonte', case when ads_dias_reais > 0 then 'tt_ads_diario' else 'settlement+provisao' end,
  'ads_produto', case when ads_dias_reais > 0 then round(ads_produto, 2) else null end,
  'ads_live',    case when ads_dias_reais > 0 then round(ads_live, 2) else null end,
  'take_rates', (select r from tr)
) from m;
$function$;
