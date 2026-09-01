-- ml_fatura_tarifas_sync falhava com "Operation timed out after 25001 ms" (31/08
-- 01:30 — segunda ocorrência do timeout de 25s, a primeira foi na varredura de
-- 27/08). O endpoint de billing do ML é lento sob carga e a função não tinha
-- retry. Fix: CURLOPT_TIMEOUT_MS 25s → 45s + 1 re-tentativa com backoff de 10s
-- (nunca retry imediato — regra do billing ML pós-429 de 03/08/2026);
-- statement_timeout da função 60s → 180s para caber as duas tentativas.
-- Corpo idêntico ao anterior fora isso.

create or replace function public.ml_fatura_tarifas_sync(p_periodo_key text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
set statement_timeout to '180s'
as $function$
declare v_tok text; v_resp jsonb; v_key text; v_subs text := 'CPAC,BPAC,CESM,BESM'; v_try int := 0;
begin
  v_key := coalesce(p_periodo_key, to_char((now() at time zone 'America/Sao_Paulo'),'YYYY-MM')||'-01');
  select (public.ml_get_state()).access_token into v_tok;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','45000');
  loop
    v_try := v_try + 1;
    begin
      select r.content::jsonb into v_resp from extensions.http(('GET',
        'https://api.mercadolibre.com/billing/integration/periods/key/'||v_key||'/group/ML/details?document_type=BILL&limit=1000&from_id=0&detail_sub_types='||v_subs,
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL)::extensions.http_request) r;
      exit;
    exception when others then
      if v_try >= 2 then raise; end if;
      perform pg_sleep(10);
    end;
  end loop;

  insert into ml_fatura_tarifas(periodo_key, competencia_data, detail_sub_type, descricao, valor, n, atualizado_em)
  select v_key, (v_key)::date, base,
     (array_agg(desc_) filter (where is_charge))[1],
     round(sum(net),2), count(*) filter (where is_charge), now()
  from (
    select
      case when (l->'charge_info'->>'detail_sub_type') in ('CPAC','BPAC') then 'CPAC'
           when (l->'charge_info'->>'detail_sub_type') in ('CESM','BESM') then 'CESM' end as base,
      case when left(l->'charge_info'->>'detail_sub_type',1)='B' then -(l->'charge_info'->>'detail_amount')::numeric
           else (l->'charge_info'->>'detail_amount')::numeric end as net,
      l->'charge_info'->>'transaction_detail' as desc_,
      left(l->'charge_info'->>'detail_sub_type',1) <> 'B' as is_charge
    from jsonb_array_elements(coalesce(v_resp->'results','[]'::jsonb)) l
  ) x
  where base is not null
  group by base
  on conflict (periodo_key, detail_sub_type) do update
    set valor=excluded.valor, descricao=excluded.descricao, n=excluded.n,
        competencia_data=excluded.competencia_data, atualizado_em=now();

  return jsonb_build_object('periodo', v_key, 'total_linhas', (v_resp->>'total'),
    'capturado', (select coalesce(jsonb_object_agg(descricao, valor),'{}'::jsonb) from ml_fatura_tarifas where periodo_key=v_key));
end $function$;
