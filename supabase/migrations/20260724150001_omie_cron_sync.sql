-- Automação do sync da Omie (antes 100% manual — Etapa 5). (Luciano, 24/07/2026.)
--   * omie_fill_despesas(): re-sync COMPLETO das contas a pagar (ListarContasPagar, ~49 páginas de
--     100). Upsert por codigo_lancamento_omie preservando data_pagamento enriquecida. Pega tudo:
--     novos títulos, PIS/COFINS/DIFAL, reclassificações, mudança de status. É o crítico do DRE.
--   * omie_cron_diario(): roda o AP + loga em oauth_refresh_log('omie_diario'). Cron 'omie-diario'
--     05:00 BRT.
--   * omie_cron_semanal(): mov_cc completo (omie_fill_movimentos, ~143 páginas — ListarMovimentos
--     não aceita filtro de data, então full) + nomes de fornecedores. Secundário (pagamentos
--     diretos ~R$1,6k/mês, dedup, data_pagamento). Cron 'omie-semanal' domingo 05:30 BRT.

CREATE OR REPLACE FUNCTION public.omie_fill_despesas()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','extensions' SET statement_timeout TO '280s'
AS $function$
DECLARE v_key text; v_sec text; p int := 1; resp jsonb; v_tot int := NULL; v_lidos int := 0;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name='omie_app_key';
  SELECT decrypted_secret INTO v_sec FROM vault.decrypted_secrets WHERE name='omie_app_secret';
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','30000');
  LOOP
    resp := (extensions.http_post('https://app.omie.com.br/api/v1/financas/contapagar/',
      jsonb_build_object('call','ListarContasPagar','app_key',v_key,'app_secret',v_sec,
        'param', jsonb_build_array(jsonb_build_object('pagina',p,'registros_por_pagina',500)))::text,
      'application/json')).content::jsonb;
    v_tot := (resp->>'total_de_paginas')::int;
    IF v_tot IS NULL THEN RETURN jsonb_build_object('erro', left(resp::text,200)); END IF;
    INSERT INTO public.omie_despesas AS t
      (codigo_lancamento_omie, codigo_cliente_fornecedor, codigo_categoria, valor,
       data_emissao, data_vencimento, data_pagamento, status_titulo, numero_documento, raw, ingested_at, updated_at)
    SELECT (cp->>'codigo_lancamento_omie')::bigint,
           nullif(cp->>'codigo_cliente_fornecedor','')::bigint,
           cp->>'codigo_categoria', (cp->>'valor_documento')::numeric,
           to_date(nullif(cp->>'data_emissao',''),'DD/MM/YYYY'),
           to_date(nullif(cp->>'data_vencimento',''),'DD/MM/YYYY'),
           to_date(nullif(cp->>'data_pagamento',''),'DD/MM/YYYY'),
           cp->>'status_titulo', cp->>'numero_documento', cp, now(), now()
    FROM jsonb_array_elements(resp->'conta_pagar_cadastro') cp
    ON CONFLICT (codigo_lancamento_omie) DO UPDATE SET
       codigo_cliente_fornecedor=excluded.codigo_cliente_fornecedor,
       codigo_categoria=excluded.codigo_categoria, valor=excluded.valor,
       data_emissao=excluded.data_emissao, data_vencimento=excluded.data_vencimento,
       data_pagamento=coalesce(excluded.data_pagamento, t.data_pagamento),
       status_titulo=excluded.status_titulo, numero_documento=excluded.numero_documento,
       raw=excluded.raw, updated_at=now();
    v_lidos := v_lidos + jsonb_array_length(coalesce(resp->'conta_pagar_cadastro','[]'::jsonb));
    EXIT WHEN p >= v_tot;
    p := p + 1;
    PERFORM pg_sleep(0.25);
  END LOOP;
  RETURN jsonb_build_object('paginas', p, 'total_paginas', v_tot, 'lidos', v_lidos,
    'ap_no_banco', (SELECT count(*) FROM public.omie_despesas));
END $function$;

CREATE OR REPLACE FUNCTION public.omie_cron_diario() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout TO '400s'
AS $$
DECLARE v_ap jsonb;
BEGIN
  v_ap := public.omie_fill_despesas();
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('omie_diario', 200, (v_ap->>'erro') IS NULL,
    'AP paginas='||coalesce(v_ap->>'paginas','?')||' lidos='||coalesce(v_ap->>'lidos','?')
    ||' ap_no_banco='||coalesce(v_ap->>'ap_no_banco','?')||coalesce(' ERRO='||(v_ap->>'erro'),''));
  RETURN v_ap;
END $$;

CREATE OR REPLACE FUNCTION public.omie_cron_semanal() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout TO '900s'
AS $$
DECLARE v_mov jsonb; v_forn jsonb;
BEGIN
  BEGIN v_mov := public.omie_fill_movimentos(1, 999); EXCEPTION WHEN OTHERS THEN v_mov := jsonb_build_object('erro',SQLERRM); END;
  BEGIN v_forn := public.omie_fill_fornecedores(300); EXCEPTION WHEN OTHERS THEN v_forn := jsonb_build_object('erro',SQLERRM); END;
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('omie_semanal', 200, (v_mov->>'erro') IS NULL,
    'mov_cc='||left(v_mov::text,80)||' | forn='||left(v_forn::text,80));
  RETURN jsonb_build_object('mov', v_mov, 'forn', v_forn);
END $$;

SELECT cron.schedule('omie-diario','0 8 * * *', $$SET statement_timeout='400s'; SELECT public.omie_cron_diario()$$);
SELECT cron.schedule('omie-semanal','30 8 * * 0', $$SET statement_timeout='900s'; SELECT public.omie_cron_semanal()$$);
