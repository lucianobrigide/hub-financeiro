-- Captura das tarifas cobradas na FATURA do ML (debited_from_operation = NO, vencimento) que
-- NÃO são capturadas por nenhuma outra fonte do Hub. Reconciliação de 22/07/2026 (Luciano):
--   * Cobrado na operação (YES) já está no líquido de cada venda -> não recapturar.
--   * Fatura já capturada: ADS (ml_ads_diario), afiliados (ml_afiliados), DIFAL (ml_difal),
--     devoluções (ml_devolucoes), Full armazenamento/coleta (ml_full_faturamento).
--   * Fatura que FALTAVA: Assessoria comercial (CPAC, ~R$1,8k->7k/mês) e Manutenção da
--     Minha página (CESM, ~R$100-200/mês). Vão para o DRE em R6 (Fixo_Outros), só no DRE.
-- Valor é líquido de cancelamentos (sub_types B* subtraem: BPAC, BESM).
-- Grão: (periodo_key, base sub_type). Competência = 1º dia do mês do periodo_key.
CREATE TABLE IF NOT EXISTS public.ml_fatura_tarifas (
  periodo_key      text NOT NULL,
  competencia_data date NOT NULL,
  detail_sub_type  text NOT NULL,
  descricao        text,
  valor            numeric NOT NULL DEFAULT 0,
  n                int NOT NULL DEFAULT 0,
  atualizado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (periodo_key, detail_sub_type)
);
ALTER TABLE public.ml_fatura_tarifas ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.ml_fatura_tarifas TO service_role;

-- Puxa da API de billing só os sub_types-alvo (poucas linhas -> 1 request, sem rate limit),
-- líquida cancelamentos e faz upsert por período.
CREATE OR REPLACE FUNCTION public.ml_fatura_tarifas_sync(p_periodo_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions' SET statement_timeout TO '60s'
AS $$
DECLARE v_tok text; v_resp jsonb; v_key text; v_subs text := 'CPAC,BPAC,CESM,BESM';
BEGIN
  v_key := COALESCE(p_periodo_key, to_char((now() AT TIME ZONE 'America/Sao_Paulo'),'YYYY-MM')||'-01');
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','25000');
  SELECT r.content::jsonb INTO v_resp
  FROM extensions.http(('GET',
    'https://api.mercadolibre.com/billing/integration/periods/key/'||v_key||'/group/ML/details?document_type=BILL&limit=1000&from_id=0&detail_sub_types='||v_subs,
    ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL)::extensions.http_request) r;

  INSERT INTO public.ml_fatura_tarifas(periodo_key, competencia_data, detail_sub_type, descricao, valor, n, atualizado_em)
  SELECT v_key, (v_key)::date, base,
     (array_agg(desc_) FILTER (WHERE is_charge))[1],
     round(sum(net),2), count(*) FILTER (WHERE is_charge), now()
  FROM (
    SELECT
      CASE WHEN (l->'charge_info'->>'detail_sub_type') IN ('CPAC','BPAC') THEN 'CPAC'
           WHEN (l->'charge_info'->>'detail_sub_type') IN ('CESM','BESM') THEN 'CESM' END AS base,
      CASE WHEN left(l->'charge_info'->>'detail_sub_type',1)='B' THEN -(l->'charge_info'->>'detail_amount')::numeric
           ELSE (l->'charge_info'->>'detail_amount')::numeric END AS net,
      l->'charge_info'->>'transaction_detail' AS desc_,
      left(l->'charge_info'->>'detail_sub_type',1) <> 'B' AS is_charge
    FROM jsonb_array_elements(COALESCE(v_resp->'results','[]'::jsonb)) l
  ) x
  WHERE base IS NOT NULL
  GROUP BY base
  ON CONFLICT (periodo_key, detail_sub_type) DO UPDATE
    SET valor=EXCLUDED.valor, descricao=EXCLUDED.descricao, n=EXCLUDED.n,
        competencia_data=EXCLUDED.competencia_data, atualizado_em=now();

  RETURN jsonb_build_object('periodo', v_key, 'total_linhas', (v_resp->>'total'),
    'capturado', (SELECT COALESCE(jsonb_object_agg(descricao, valor),'{}'::jsonb) FROM public.ml_fatura_tarifas WHERE periodo_key=v_key));
END $$;

-- Wrapper do cron: ressincroniza mês corrente + anterior (o anterior finaliza no início do mês seguinte).
CREATE OR REPLACE FUNCTION public.ml_fatura_tarifas_cron()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.ml_fatura_tarifas_sync(to_char((now() AT TIME ZONE 'America/Sao_Paulo'),'YYYY-MM')||'-01');
  PERFORM public.ml_fatura_tarifas_sync(to_char((now() AT TIME ZONE 'America/Sao_Paulo') - interval '1 month','YYYY-MM')||'-01');
END $$;

-- Cron diário (idempotente). "Não esquecer de capturar" -> roda todo dia, mantém o mês fresco.
SELECT cron.schedule('ml_fatura_tarifas','30 4 * * *', $$SELECT public.ml_fatura_tarifas_cron()$$);

-- Backfill inicial de junho/2026.
SELECT public.ml_fatura_tarifas_sync('2026-06-01');
