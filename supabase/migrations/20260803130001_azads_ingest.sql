-- Ingestão do gasto Amazon Ads (Reports v3). Os relatórios são ASSÍNCRONOS
-- (create → fila da Amazon → download), então a ingestão é uma fila de jobs em
-- 3 estados honestos: PENDENTE (Amazon ainda gerando — não é sucesso nem falha),
-- INGERIDO, FALHOU. A Edge amazon-ads-ingest pede/colhe; o PG guarda tudo.
-- REGRA DURA: nada estimado — a tabela azads_gastos espelha o snapshot do
-- relatório (replace por janela+produto, nunca merge que deixaria valor morto).
-- SEM CRON NESTE ARQUIVO: agendamento só entra depois do item 6 (API × painel) bater.

-- Gasto diário por campanha (date = fuso do perfil, America/Sao_Paulo)
create table if not exists public.azads_gastos (
  data          date        not null,
  campaign_id   text        not null,
  ad_product    text        not null,  -- SPONSORED_PRODUCTS | SPONSORED_BRANDS | SPONSORED_DISPLAY
  campaign_name text,
  cost          numeric(14,2) not null default 0,
  impressions   bigint,
  clicks        int,
  atualizado_em timestamptz not null default now(),
  primary key (data, campaign_id, ad_product)
);
comment on table public.azads_gastos is
  'Gasto diario Amazon Ads por campanha (Reports v3, cost em BRL sem impostos de fatura). Snapshot do relatorio: azads_replace_gastos substitui a janela inteira por produto.';
alter table public.azads_gastos enable row level security;

-- Fila de relatórios pedidos à Amazon
create table if not exists public.azads_report_jobs (
  report_id     text primary key,
  ad_product    text not null,
  de            date not null,
  ate           date not null,
  status        text not null default 'PENDENTE'
                check (status in ('PENDENTE','INGERIDO','FALHOU')),
  tentativas    int  not null default 0,
  detalhe       text,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.azads_report_jobs enable row level security;

-- Upsert de job (criação/re-registro)
create or replace function public.azads_job_upsert(
  p_report_id text, p_ad_product text, p_de date, p_ate date
) returns void language sql security definer set search_path to 'public'
as $$
  insert into public.azads_report_jobs (report_id, ad_product, de, ate)
  values (p_report_id, p_ad_product, p_de, p_ate)
  on conflict (report_id) do nothing;
$$;

-- Jobs abertos (para a colheita)
create or replace function public.azads_jobs_abertos()
returns table(report_id text, ad_product text, de date, ate date, tentativas int)
language sql stable security definer set search_path to 'public'
as $$
  select report_id, ad_product, de, ate, tentativas
  from public.azads_report_jobs where status = 'PENDENTE'
  order by criado_em;
$$;

-- Marca tentativa de polling (job segue pendente)
create or replace function public.azads_job_tentativa(p_report_id text)
returns void language sql security definer set search_path to 'public'
as $$
  update public.azads_report_jobs
     set tentativas = tentativas + 1, atualizado_em = now()
   where report_id = p_report_id;
$$;

-- Finaliza job (INGERIDO/FALHOU)
create or replace function public.azads_job_finaliza(
  p_report_id text, p_status text, p_detalhe text
) returns void language sql security definer set search_path to 'public'
as $$
  update public.azads_report_jobs
     set status = p_status, detalhe = left(p_detalhe, 500), atualizado_em = now()
   where report_id = p_report_id;
$$;

-- Substitui a janela do produto pelo snapshot do relatório (delete+insert na
-- MESMA transação). Merge/upsert deixaria linha morta quando a Amazon invalida
-- cliques e um dia some do relatório novo — replace é o único caminho honesto.
create or replace function public.azads_replace_gastos(
  p_ad_product text, p_de date, p_ate date, p_rows jsonb
) returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_del int; v_ins int; v_total numeric;
begin
  delete from public.azads_gastos
   where ad_product = p_ad_product and data between p_de and p_ate;
  get diagnostics v_del = row_count;

  insert into public.azads_gastos (data, campaign_id, ad_product, campaign_name, cost, impressions, clicks, atualizado_em)
  select
    (r->>'date')::date,
    r->>'campaignId',
    p_ad_product,
    r->>'campaignName',
    coalesce((r->>'cost')::numeric, 0),
    (r->>'impressions')::bigint,
    (r->>'clicks')::int,
    now()
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) as r;
  get diagnostics v_ins = row_count;

  select coalesce(sum(cost), 0) into v_total
  from public.azads_gastos
  where ad_product = p_ad_product and data between p_de and p_ate;

  return jsonb_build_object('removidas', v_del, 'inseridas', v_ins, 'gasto_janela', v_total);
end $$;

-- Leitura do mês para o card/DRE (LIGAÇÃO AO CARD SÓ DEPOIS DO ITEM 6 BATER).
-- ads_total_mes: soma de todos os produtos; dias_com_dado: cobertura honesta.
create or replace function public.azads_ads(p_month text)
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'ads_total_mes', coalesce(sum(cost), 0),
    'dias_com_dado', count(distinct data),
    'ultima_atualizacao', max(atualizado_em)
  )
  from public.azads_gastos
  where to_char(data, 'YYYY-MM') = p_month;
$$;

-- Chamada PG → Edge amazon-ads-ingest, tolerante a falha (clone do az_edge_call:
-- timeout/erro de rede vira erro logável, não aborta o orquestrador).
create or replace function public.azads_edge_call(p_body jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public','extensions','vault'
as $$
declare
  v_url text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/amazon-ads-ingest';
  v_key text; v_status int; v_raw text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'azads_token_key';
  if v_key is null or v_key = '' then
    return jsonb_build_object('http_status', 0, 'body', jsonb_build_object('error','missing_key'));
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '150000');
  begin
    select r.status, r.content into v_status, v_raw
    from extensions.http((
      'POST', v_url, array[ extensions.http_header('x-api-key', v_key) ],
      'application/json', p_body::text
    )::extensions.http_request) as r;
  exception when others then
    return jsonb_build_object('http_status', 0,
      'body', jsonb_build_object('error','edge_call_falhou','detalhe', left(SQLERRM, 200)));
  end;
  return jsonb_build_object('http_status', v_status,
    'body', case when left(coalesce(v_raw,''),1) = '{' then v_raw::jsonb else to_jsonb(coalesce(v_raw,'')) end);
end $$;

-- Orquestrador diário: colhe jobs pendentes e pede a janela D-3..D-1 (o cost
-- flutua ~72h por remoção de cliques inválidos — re-pedir a janela é a
-- reconferência). Log honesto em ml_cron_log (job azads-diario).
create or replace function public.azads_cron_diario()
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_de  date := (now() at time zone 'America/Sao_Paulo')::date - 3;
  v_ate date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_t timestamptz := clock_timestamp();
  v_res jsonb;
begin
  v_res := azads_edge_call(jsonb_build_object('modo','ciclo','de', v_de::text, 'ate', v_ate::text));
  insert into public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  values (
    'azads-diario', v_ate,
    (v_res->>'http_status') = '200',
    (v_res->>'http_status')::int,
    coalesce((v_res->'body'->>'jobs_colhidos')::int, 0),
    coalesce((v_res->'body'->>'gasto_ingerido')::numeric, 0),
    (extract(epoch from clock_timestamp() - v_t) * 1000)::int,
    coalesce(v_res->'body'->>'resumo', v_res->'body'->>'error', 'sem corpo'),
    v_res
  );
  return v_res;
end $$;

-- Colheita extra (30 min depois do diário): só colhe, não pede janela nova.
create or replace function public.azads_cron_colher()
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_t timestamptz := clock_timestamp(); v_res jsonb;
begin
  v_res := azads_edge_call(jsonb_build_object('modo','colher'));
  insert into public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  values (
    'azads-colher', (now() at time zone 'America/Sao_Paulo')::date - 1,
    (v_res->>'http_status') = '200',
    (v_res->>'http_status')::int,
    coalesce((v_res->'body'->>'jobs_colhidos')::int, 0),
    coalesce((v_res->'body'->>'gasto_ingerido')::numeric, 0),
    (extract(epoch from clock_timestamp() - v_t) * 1000)::int,
    coalesce(v_res->'body'->>'resumo', v_res->'body'->>'error', 'sem corpo'),
    v_res
  );
  return v_res;
end $$;

revoke all on function public.azads_job_upsert(text,text,date,date) from public, anon, authenticated;
revoke all on function public.azads_jobs_abertos() from public, anon, authenticated;
revoke all on function public.azads_job_tentativa(text) from public, anon, authenticated;
revoke all on function public.azads_job_finaliza(text,text,text) from public, anon, authenticated;
revoke all on function public.azads_replace_gastos(text,date,date,jsonb) from public, anon, authenticated;
revoke all on function public.azads_ads(text) from public, anon, authenticated;
revoke all on function public.azads_edge_call(jsonb) from public, anon, authenticated;
revoke all on function public.azads_cron_diario() from public, anon, authenticated;
revoke all on function public.azads_cron_colher() from public, anon, authenticated;
grant execute on function public.azads_job_upsert(text,text,date,date) to service_role;
grant execute on function public.azads_jobs_abertos() to service_role;
grant execute on function public.azads_job_tentativa(text) to service_role;
grant execute on function public.azads_job_finaliza(text,text,text) to service_role;
grant execute on function public.azads_replace_gastos(text,date,date,jsonb) to service_role;
grant execute on function public.azads_ads(text) to service_role;
grant execute on function public.azads_edge_call(jsonb) to service_role;
grant execute on function public.azads_cron_diario() to service_role;
grant execute on function public.azads_cron_colher() to service_role;
