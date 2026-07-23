-- CCOLPA "Tarifa por serviço de coleta pré-agendada" — custo de Full que NÃO vem no endpoint
-- dedicado /group/ML/full/details (concept_type nulo, não é FULFILLMENT), então escapava da
-- ingestão do Full e não entrava em "Despesas com o Full" (C7). (Luciano, 23/07/2026.)
-- Captura do billing principal (group/ML/details, sub_type CCOLPA), inserindo em
-- ml_full_faturamento via ml_upsert_full → ml_full() já soma no C7, POR DIA (creation_date),
-- competência correta, seguindo a regra dos outros gastos de Full. Cancelamentos (B*) subtraem.

CREATE OR REPLACE FUNCTION public.ml_full_ccolpa_sync(p_periodo_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions' SET statement_timeout TO '60s'
AS $$
DECLARE v_tok text; v_resp jsonb; v_key text; v_rows jsonb; v_n int;
BEGIN
  v_key := COALESCE(p_periodo_key, to_char((now() AT TIME ZONE 'America/Sao_Paulo'),'YYYY-MM')||'-01');
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','25000');
  SELECT r.content::jsonb INTO v_resp
  FROM extensions.http(('GET',
    'https://api.mercadolibre.com/billing/integration/periods/key/'||v_key||'/group/ML/details?document_type=BILL&limit=1000&from_id=0&detail_sub_types=CCOLPA,BCOLPA',
    ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL)::extensions.http_request) r;
  SELECT jsonb_agg(jsonb_build_object(
     'detail_id', (l->'charge_info'->>'detail_id')::bigint,
     'creation_date', left(l->'charge_info'->>'creation_date_time',10),
     'creation_date_time', l->'charge_info'->>'creation_date_time',
     'tipo', l->'charge_info'->>'detail_type',
     'detail_sub_type', l->'charge_info'->>'detail_sub_type',
     'detail_amount', CASE WHEN left(l->'charge_info'->>'detail_sub_type',1)='B'
                          THEN -(l->'charge_info'->>'detail_amount')::numeric
                          ELSE (l->'charge_info'->>'detail_amount')::numeric END,
     'transaction_detail', l->'charge_info'->>'transaction_detail',
     'concept_type', 'COLETA_PREAGENDADA',
     'warehouse_id', NULL,'sku', NULL,'item_id', NULL,'inventory_id', NULL,
     'quantity', NULL,'amount_per_unit', NULL,
     'legal_document_number', l->'charge_info'->>'legal_document_number',
     'document_id', nullif(l->'document_info'->>'document_id','')::bigint,
     'periodo_key', v_key
  )) INTO v_rows
  FROM jsonb_array_elements(COALESCE(v_resp->'results','[]'::jsonb)) l;
  IF v_rows IS NULL THEN RETURN jsonb_build_object('periodo', v_key, 'linhas', 0); END IF;
  SELECT public.ml_upsert_full(v_rows) INTO v_n;
  RETURN jsonb_build_object('periodo', v_key, 'upsert', v_n,
    'total_ccolpa', (SELECT round(sum((e->>'detail_amount')::numeric),2) FROM jsonb_array_elements(v_rows) e));
END $$;

CREATE OR REPLACE FUNCTION public.ml_full_ccolpa_cron()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.ml_full_ccolpa_sync(to_char((now() AT TIME ZONE 'America/Sao_Paulo'),'YYYY-MM')||'-01');
  PERFORM public.ml_full_ccolpa_sync(to_char((now() AT TIME ZONE 'America/Sao_Paulo') - interval '1 month','YYYY-MM')||'-01');
END $$;

SELECT cron.schedule('ml_full_ccolpa','40 4 * * *', $$SELECT public.ml_full_ccolpa_cron()$$);
SELECT public.ml_full_ccolpa_sync('2026-06-01');
