-- ============================================================================
-- Amazon — recebíveis (F.C. Projetado) · 17/08/2026
-- ============================================================================
-- Fonte: SP-API Finances v0, listFinancialEventGroups, via Edge `az-recebiveis`
-- (a Amazon só é acessível por Edge Function — o PG não assina LWA/SigV4).
-- A Edge tem 2 modos: `grupos` (usado aqui) e `eventos` (drill-down por grupo).
--
-- Como o dinheiro anda na Amazon (verificado 17/08/2026): o saldo vive em
-- "financial event groups" de ~14 dias. O grupo ABERTO acumula o ciclo corrente;
-- quando fecha, ganha FundTransferDate e FundTransferStatus:
--   · Processing → transferência disparada, dinheiro A CAMINHO do banco (com DATA)
--   · Succeeded  → já caiu (não é mais recebível)
--   · Unknown    → grupos de saldo negativo/ajuste; não conta como a receber
--     (na 1ª carga: 18 grupos Succeeded = R$ 16.497,83 e 9 Unknown = −R$ 17.895,43)
--
-- Régua: a receber = Σ OriginalTotal dos grupos Closed+Processing (COM data de
-- transferência) + Σ OriginalTotal dos grupos Open (ciclo corrente, SEM data —
-- a Amazon não publica quando o ciclo fecha; ~14 dias é observação, não dado).
-- Negativos entram como estão: são débitos que vão abater o repasse.
-- Este é o ÚNICO canal com cronograma PARCIAL — daí o campo `sem_data`, que a UI
-- mostra em separado (`valorSemData`) pra as faixas por prazo não mentirem.
--
-- 1ª carga: 37 grupos → R$ 21.151,13 a caminho (4 grupos, transferência de 17/08)
-- e −R$ 117,77 no ciclo aberto. Total R$ 21.033,36.

create table if not exists az_finance_groups (
  group_id         text primary key,
  processing_status text,          -- Open | Closed
  transfer_status  text,           -- Processing | Succeeded | Unknown | null
  transfer_date    timestamptz,    -- quando o dinheiro foi/será transferido
  grupo_inicio     timestamptz,
  grupo_fim        timestamptz,
  total            numeric(14,2),  -- OriginalTotal
  saldo_inicial    numeric(14,2),  -- BeginningBalance
  account_tail     text,
  atualizado_em    timestamptz not null default now()
);

comment on table az_finance_groups is
  'Grupos financeiros da Amazon (ciclos de ~14 dias). Base dos recebíveis: Closed+Processing = dinheiro a caminho (com data); Open = ciclo corrente acumulando (sem data).';

create index if not exists az_fg_status_idx on az_finance_groups (processing_status, transfer_status);

create or replace function az_fill_recebiveis(p_dias int default 120)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_key text; v_status int; v_raw text; v_resp jsonb; v_x jsonb;
  v_lidos int := 0; v_ini timestamptz := clock_timestamp(); v_erro text := null;
begin
  if not pg_try_advisory_lock(hashtext('az_fill_recebiveis')) then
    return jsonb_build_object('ok', false, 'mensagem', 'já existe uma ingestão rodando');
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'az_token_key';
  if v_key is null or v_key = '' then
    perform pg_advisory_unlock(hashtext('az_fill_recebiveis'));
    return jsonb_build_object('ok', false, 'mensagem', 'sem az_token_key no Vault');
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '120000');

  begin
    select r.status, r.content into v_status, v_raw
    from extensions.http((
      'POST',
      'https://klwczmapuupensozxbsr.supabase.co/functions/v1/az-recebiveis',
      array[extensions.http_header('x-api-key', v_key)],
      'application/json',
      jsonb_build_object('modo','grupos','dias',p_dias)::text
    )::extensions.http_request) r;
  exception when others then
    v_erro := 'edge_call falhou: ' || left(sqlerrm, 200);
  end;

  if v_erro is null and v_status <> 200 then
    v_erro := 'Edge HTTP ' || v_status || ': ' || left(coalesce(v_raw,''), 200);
  end if;

  if v_erro is null then
    v_resp := v_raw::jsonb;
    for v_x in select * from jsonb_array_elements(coalesce(v_resp->'grupos','[]'::jsonb)) loop
      insert into az_finance_groups as g (
        group_id, processing_status, transfer_status, transfer_date,
        grupo_inicio, grupo_fim, total, saldo_inicial, account_tail, atualizado_em
      ) values (
        v_x->>'FinancialEventGroupId',
        v_x->>'ProcessingStatus',
        nullif(v_x->>'FundTransferStatus',''),
        nullif(v_x->>'FundTransferDate','')::timestamptz,
        nullif(v_x->>'FinancialEventGroupStart','')::timestamptz,
        nullif(v_x->>'FinancialEventGroupEnd','')::timestamptz,
        nullif(v_x->'OriginalTotal'->>'CurrencyAmount','')::numeric,
        nullif(v_x->'BeginningBalance'->>'CurrencyAmount','')::numeric,
        nullif(v_x->>'AccountTail',''),
        now()
      )
      on conflict (group_id) do update set
        processing_status = excluded.processing_status,
        transfer_status   = excluded.transfer_status,
        transfer_date     = excluded.transfer_date,
        grupo_fim         = excluded.grupo_fim,
        total             = excluded.total,
        saldo_inicial     = excluded.saldo_inicial,
        account_tail      = excluded.account_tail,
        atualizado_em     = now();
      v_lidos := v_lidos + 1;
    end loop;
  end if;

  perform pg_advisory_unlock(hashtext('az_fill_recebiveis'));

  insert into ml_cron_log(job, sucesso, http_status, pedidos, duracao_ms, mensagem)
  values ('az_recebiveis', v_erro is null, v_status, v_lidos,
          (extract(epoch from (clock_timestamp()-v_ini))*1000)::int,
          coalesce(v_erro, 'ok — ' || v_lidos || ' grupos financeiros'));

  return jsonb_build_object('ok', v_erro is null, 'grupos', v_lidos,
                            'mensagem', coalesce(v_erro,'ok'));
end;
$function$;

comment on function az_fill_recebiveis(int) is
  'Ingere os financial event groups da Amazon (via Edge az-recebiveis) — base dos recebíveis do F.C. Projetado.';

create or replace function az_recebiveis()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as d),
  -- Dinheiro a caminho do banco: fechado e com transferência em processamento.
  transito as (
    select (transfer_date at time zone 'America/Sao_Paulo')::date as dia,
           round(sum(total),2) as valor
    from az_finance_groups
    where processing_status = 'Closed'
      and transfer_status = 'Processing'
      and transfer_date is not null
    group by 1
  ),
  -- Ciclo corrente: valor real já acumulado, mas a Amazon não diz quando fecha.
  aberto as (
    select coalesce(round(sum(total),2), 0) as valor, count(*) as grupos
    from az_finance_groups
    where processing_status = 'Open' and coalesce(total,0) <> 0
  )
  select jsonb_build_object(
    'referencia',    (select d from hoje),
    'total',         coalesce((select sum(valor) from transito),0) + (select valor from aberto),
    'em_transito',   coalesce((select sum(valor) from transito),0),
    -- Parte do total que NÃO tem data (ciclo aberto) — a UI mostra separado.
    'sem_data',      (select valor from aberto),
    'grupos_abertos',(select grupos from aberto),
    'atualizado_em', (select max(atualizado_em) from az_finance_groups),
    'dias', coalesce(
      (select jsonb_agg(jsonb_build_object('data', dia, 'valor', valor) order by dia)
       from transito where valor <> 0),
      '[]'::jsonb)
  );
$function$;

comment on function az_recebiveis() is
  'Recebíveis Amazon: grupos Closed+Processing viram cronograma (têm FundTransferDate) e o grupo Open entra no total sem data (a Amazon não publica quando o ciclo fecha).';

revoke all on function az_fill_recebiveis(int) from public, anon, authenticated;
revoke all on function az_recebiveis() from public, anon, authenticated;
grant execute on function az_fill_recebiveis(int) to service_role;
grant execute on function az_recebiveis() to service_role;

alter table az_finance_groups enable row level security;
