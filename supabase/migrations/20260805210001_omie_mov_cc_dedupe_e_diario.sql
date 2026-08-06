-- Corrige omie_fill_movimentos: a Omie devolve o mesmo nCodMovCC repetido na
-- mesma página, e o upsert quebrava com "ON CONFLICT DO UPDATE command cannot
-- affect row a second time" (cron semanal falhando desde 26/07; omie_mov_cc
-- congelada em 20/07). Deduplica com DISTINCT ON, ignora movimentos sem
-- nCodMovCC (registros NFE sem conciliação, sem valor) e adiciona filtro
-- opcional por data de pagamento para varredura incremental no cron diário.

DROP FUNCTION IF EXISTS public.omie_fill_movimentos(integer, integer);

CREATE OR REPLACE FUNCTION public.omie_fill_movimentos(
  p_de integer, p_ate integer, p_dt_de date DEFAULT NULL, p_dt_ate date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_key text; v_sec text; p int; resp jsonb; v_tot_pag int := NULL; v_param jsonb;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name='omie_app_key';
  SELECT decrypted_secret INTO v_sec FROM vault.decrypted_secrets WHERE name='omie_app_secret';
  FOR p IN p_de..p_ate LOOP
    v_param := jsonb_build_object('nPagina', p, 'nRegPorPagina', 500);
    IF p_dt_de  IS NOT NULL THEN v_param := v_param || jsonb_build_object('dDtPagtoDe',  to_char(p_dt_de,  'DD/MM/YYYY')); END IF;
    IF p_dt_ate IS NOT NULL THEN v_param := v_param || jsonb_build_object('dDtPagtoAte', to_char(p_dt_ate, 'DD/MM/YYYY')); END IF;
    resp := (extensions.http_post('https://app.omie.com.br/api/v1/financas/mf/',
      jsonb_build_object('call','ListarMovimentos','app_key',v_key,'app_secret',v_sec,
        'param', jsonb_build_array(v_param))::text,
      'application/json')).content::jsonb;
    IF resp ? 'faultstring' THEN
      RAISE EXCEPTION 'Omie ListarMovimentos pagina %: %', p, resp->>'faultstring';
    END IF;
    v_tot_pag := (resp->>'nTotPaginas')::int;
    INSERT INTO public.omie_mov_cc AS t
      (n_cod_mov_cc, n_cod_cliente, n_cod_titulo, codigo_categoria, codigo_projeto, valor, data_pagamento, c_grupo, c_natureza, c_status, raw, updated_at)
    SELECT DISTINCT ON ((d->>'nCodMovCC')::bigint)
      (d->>'nCodMovCC')::bigint, nullif(d->>'nCodCliente','')::bigint, nullif(d->>'nCodTitulo','')::bigint, d->>'cCodCateg',
      nullif(d->>'cCodProjeto',''), (d->>'nValorMovCC')::numeric,
      to_date(nullif(d->>'dDtPagamento',''),'DD/MM/YYYY'), d->>'cGrupo', d->>'cNatureza', d->>'cStatus', m, now()
    FROM jsonb_array_elements(resp->'movimentos') m, lateral (SELECT m->'detalhes' AS d) x
    WHERE m->'detalhes'->>'cGrupo' = 'CONTA_CORRENTE_PAG'
      AND nullif(m->'detalhes'->>'nCodMovCC','') IS NOT NULL
    ORDER BY (d->>'nCodMovCC')::bigint
    ON CONFLICT (n_cod_mov_cc) DO UPDATE SET
      n_cod_titulo=excluded.n_cod_titulo, codigo_categoria=excluded.codigo_categoria, codigo_projeto=excluded.codigo_projeto,
      valor=excluded.valor, data_pagamento=excluded.data_pagamento, c_status=excluded.c_status, raw=excluded.raw, updated_at=now();
    EXIT WHEN p >= v_tot_pag;
  END LOOP;
  RETURN jsonb_build_object('ultima_pagina', p, 'total_paginas', v_tot_pag, 'mov_cc_no_banco', (SELECT count(*) FROM public.omie_mov_cc));
END $function$;

-- Cron diário passa a varrer também a conta corrente (incremental, últimos 45 dias).
-- Antes só o cron semanal (domingo) cobria mov_cc.
CREATE OR REPLACE FUNCTION public.omie_cron_diario()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '400s'
AS $function$
DECLARE v_ap jsonb; v_mov jsonb;
BEGIN
  v_ap := public.omie_fill_despesas();
  BEGIN
    v_mov := public.omie_fill_movimentos(1, 999, (current_date - 45), NULL);
  EXCEPTION WHEN OTHERS THEN
    v_mov := jsonb_build_object('erro', SQLERRM);
  END;
  INSERT INTO public.oauth_refresh_log(conta, http_status, success, message)
  VALUES ('omie_diario', 200, (v_ap->>'erro') IS NULL AND (v_mov->>'erro') IS NULL,
    'AP paginas='||coalesce(v_ap->>'paginas','?')||' lidos='||coalesce(v_ap->>'lidos','?')
    ||' ap_no_banco='||coalesce(v_ap->>'ap_no_banco','?')||coalesce(' ERRO_AP='||(v_ap->>'erro'),'')
    ||' | mov_cc='||left(coalesce(v_mov::text,'?'),120));
  RETURN jsonb_build_object('ap', v_ap, 'mov', v_mov);
END $function$;
