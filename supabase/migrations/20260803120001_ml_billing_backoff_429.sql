-- FIX: billing ML falhava todo dia desde 31/07 com "API nao respondeu nenhuma pagina".
--
-- CAUSA REAL (reproduzida ao vivo 03/08): HTTP 429 {"message":"local_rate_limited"}.
-- O ML apertou o rate limit do endpoint /billing/integration/.../details por volta de
-- 31/07. No cron das 06:00, os passos full/difal/seguidores martelam esse MESMO endpoint
-- (dezenas de paginas) logo antes do passo de billing — que chega com o limite estourado.
--
-- POR QUE O CODIGO NAO VIA O 429: o retry por pagina so reagia a EXCECAO (timeout/parse).
-- Um 429 chega como JSON valido → v_resp IS NOT NULL sai do retry na hora, sem pausa;
-- 'total' e 'results' nao existem no corpo do erro → o walk desiste em ~150ms e as 4
-- tentativas (tambem sem pausa) repetem o 429. O status HTTP nunca era checado.
--
-- FIX (cirurgico, estrutura preservada):
-- 1) ml_fill_billing: captura r.status; status != 200 conta como falha de pagina, com
--    v_erro honesto ('HTTP 429: local_rate_limited') e backoff pg_sleep(5*retry).
--    Entre tentativas do walk, se a API nem devolveu o total (cenario rate-limited),
--    backoff pg_sleep(10*try). Pior caso ~120s, dentro do statement_timeout de 300s.
-- 2) ml_api_total (verificador, mesmo endpoint): backoff pg_sleep(2*i) entre tentativas.
-- 3) ZERO SILENCIOSO (descoberto testando o fix): sob throttle a API tambem pode responder
--    200 com total=0 e results vazio — a MESMA query, minutos depois, devolve total=328.
--    total=0 com linhas ja gravadas no banco agora e tratado como suspeito: re-le com
--    backoff e, se persistir nas 4 tentativas, retorna ok=false honesto (nunca "completo").
--    Investigacao completa: memoria da sessao 03/08 + testes ao vivo (BPAD=50, CDLIT=38,
--    lista inteira=328 quando calmo; 0 quando throttled).
--
-- Aplicado no banco via MCP em duas levas (backoff_429 + zero_silencioso); este arquivo
-- e a definicao final consolidada (repo == banco).

CREATE OR REPLACE FUNCTION public.ml_fill_billing(p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
 SET statement_timeout TO '300s'
AS $function$
DECLARE
  v_tok text; v_from bigint; v_page int; v_resp jsonb; v_res jsonb;
  v_last bigint; v_grav int; v_total_api int := NULL; v_no_banco int;
  v_try int := 0; v_paginas_ok int := 0; v_erro text := NULL; v_retry int;
  v_st int;
  v_tipos text := 'BPAD,CXDED,CDSDB,CFPB,CXDID,BXDED,BDSDB,BXDID';
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'sem_token', 'key', p_key);
  END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','90000');

  <<tentativas>>
  LOOP
    v_try := v_try + 1;
    v_from := 0; v_page := 0; v_grav := 0;

    LOOP
      v_page := v_page + 1;
      EXIT WHEN v_page > 200;

      -- busca a página com retry (a API de billing é grande/flaky E rate-limita em 429)
      v_resp := NULL;
      FOR v_retry IN 1..3 LOOP
        BEGIN
          SELECT r.status, (r.content::jsonb) INTO v_st, v_resp
          FROM extensions.http((
            'GET',
            'https://api.mercadolibre.com/billing/integration/periods/key/'||p_key||
            '/group/ML/details?document_type=BILL&detail_sub_types='||v_tipos||
            '&limit=50&from_id='||v_from||'&sort_by=ID&order_by=ASC',
            ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL
          )::extensions.http_request) r;
          -- 429/5xx chegam como JSON valido: sem checar o status, o erro passava por
          -- "pagina vazia" e o walk desistia sem pausa nenhuma.
          IF v_st IS DISTINCT FROM 200 THEN
            v_erro := 'HTTP '||coalesce(v_st::text,'?')||
                      coalesce(': '||(v_resp->>'message'), '');
            v_resp := NULL;
            PERFORM pg_sleep(5 * v_retry);
          END IF;
          EXIT WHEN v_resp IS NOT NULL;
        EXCEPTION WHEN OTHERS THEN
          v_resp := NULL; v_erro := 'http: '||SQLERRM;
          PERFORM pg_sleep(1);
        END;
      END LOOP;

      IF v_resp IS NULL THEN EXIT; END IF;
      IF v_total_api IS NULL THEN v_total_api := (v_resp->>'total')::int; END IF;
      v_res := v_resp->'results';
      EXIT WHEN v_res IS NULL OR jsonb_array_length(v_res) = 0;
      v_paginas_ok := v_paginas_ok + 1;

      INSERT INTO public.ml_billing_linhas
        (detail_id, creation_date, creation_date_time, detail_type, detail_sub_type,
         detail_amount, transaction_detail, order_id, periodo_key)
      SELECT (e->'charge_info'->>'detail_id')::bigint,
             (left(e->'charge_info'->>'creation_date_time',10))::date,
             (e->'charge_info'->>'creation_date_time')::timestamptz,
             e->'charge_info'->>'detail_type',
             e->'charge_info'->>'detail_sub_type',
             (e->'charge_info'->>'detail_amount')::numeric,
             e->'charge_info'->>'transaction_detail',
             nullif(e->'sales_info'->0->>'order_id','')::bigint,
             p_key
      FROM jsonb_array_elements(v_res) e
      ON CONFLICT (detail_id) DO UPDATE SET
        detail_amount = excluded.detail_amount,
        creation_date = excluded.creation_date,
        detail_sub_type = excluded.detail_sub_type,
        transaction_detail = excluded.transaction_detail,
        atualizado_em = now();

      v_grav := v_grav + jsonb_array_length(v_res);
      SELECT max((e->'charge_info'->>'detail_id')::bigint) INTO v_last
        FROM jsonb_array_elements(v_res) e;
      EXIT WHEN v_last IS NULL OR v_last = v_from;
      v_from := v_last;
    END LOOP;

    SELECT count(*) INTO v_no_banco FROM public.ml_billing_linhas WHERE periodo_key = p_key;
    -- Antes: total NULL saia na hora — no cenario rate-limited e exatamente quando
    -- se deve INSISTIR. Agora so desiste do total apos as 4 tentativas (ou quando o
    -- walk rodou paginas e a API realmente nao mandou total = Estado 2 legitimo).
    -- ZERO SILENCIOSO (visto ao vivo 03/08): sob throttle a API pode responder 200 com
    -- total=0 e results vazio — a mesma query, minutos depois, devolve total=328.
    -- total=0 com linhas ja no banco e SUSPEITO: re-le em vez de aceitar "completo".
    EXIT tentativas WHEN (v_total_api IS NOT NULL AND v_no_banco >= v_total_api
                          AND NOT (v_total_api = 0 AND v_no_banco > 0))
                      OR (v_total_api IS NULL AND v_paginas_ok > 0)
                      OR v_try >= 4;
    -- proximo walk: API rate-limited ou zero suspeito — espera esfriar e re-le o total
    IF v_total_api IS NULL OR (v_total_api = 0 AND v_no_banco > 0) THEN
      PERFORM pg_sleep(10 * v_try);
      v_total_api := NULL;
    END IF;
  END LOOP;

  IF v_paginas_ok = 0 AND v_total_api IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'verificado', false, 'key', p_key,
      'no_banco', v_no_banco, 'tentativas', v_try,
      'erro', coalesce(v_erro, 'API nao respondeu nenhuma pagina'));
  END IF;

  -- Zero silencioso persistiu nas 4 tentativas: falha honesta, nunca "completo".
  IF v_total_api = 0 AND v_no_banco > 0 THEN
    RETURN jsonb_build_object('ok', false, 'verificado', false, 'key', p_key,
      'no_banco', v_no_banco, 'tentativas', v_try,
      'erro', format('suspeito: API insiste em total=0 mas banco tem %s linhas (throttle silencioso?)', v_no_banco));
  END IF;

  IF v_total_api IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'verificado', false, 'key', p_key,
      'no_banco', v_no_banco, 'tentativas', v_try,
      'aviso', 'API nao devolveu o total; completude NAO verificada');
  END IF;

  RETURN jsonb_build_object('ok', true, 'verificado', true, 'key', p_key,
    'completo', (v_no_banco >= v_total_api),
    'no_banco', v_no_banco, 'total_api', v_total_api, 'tentativas', v_try,
    'erro', case when v_no_banco < v_total_api
                 then format('INCOMPLETO: %s de %s', v_no_banco, v_total_api) end);
END $function$;

CREATE OR REPLACE FUNCTION public.ml_api_total(p_sub_type text, p_key text, p_tentativas integer DEFAULT 3)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_tok text; v_st int; v_body text; v_total int; i int;
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN RETURN NULL; END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','60000');
  FOR i IN 1..p_tentativas LOOP
    BEGIN
      SELECT r.status, r.content INTO v_st, v_body
      FROM extensions.http((
        'GET',
        'https://api.mercadolibre.com/billing/integration/periods/key/'||p_key||
        '/group/ML/details?document_type=BILL&detail_sub_types='||p_sub_type||
        '&limit=1&from_id=0&sort_by=ID&order_by=ASC',
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL
      )::extensions.http_request) r;
      IF v_st = 200 THEN
        v_total := (v_body::jsonb->>'total')::int;
        IF v_total IS NOT NULL THEN RETURN v_total; END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;  -- timeout/parse: cai no próximo retry
    END;
    -- backoff: o endpoint rate-limita em 429 (local_rate_limited) — sem pausa,
    -- as tentativas queimam em milissegundos contra o mesmo limite.
    IF i < p_tentativas THEN PERFORM pg_sleep(2 * i); END IF;
  END LOOP;
  RETURN NULL;
END $function$;
