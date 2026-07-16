-- FIX (regressão do 1ba6e74): ml_edge_passo comparava periodo_key com text.
--
-- BUG: a conferência de completude fazia `where periodo_key in ($1,$2)` com $1/$2 = text
-- ('2026-07-01'), mas periodo_key é DATE em ml_afiliados e ml_difal (só ml_billing_linhas é
-- text). Resultado: `date = text` -> ERRO, exceção NÃO tratada -> derrubava o ml_cron_diario
-- INTEIRO no 5º passo (afiliados). O ML rodou ok até 14/07 (dia do deploy do 1ba6e74) e
-- FALHOU 15 e 16/07 — o pg_cron marcava 'failed' enquanto o log de app dizia 'ok' no último
-- passo que rodou. Quem denunciou foi a página de Crons (semáforo vem do pg_cron, não do log).
--
-- IMPACTO: o cron morre no passo afiliados -> DIFAL, billing (BPAD/fricção) e a reconferência
-- de cancelados pararam de rodar. Os passos anteriores (pedidos/comissão/frete/ADS) seguiram.
--
-- FIX: cast periodo_key::text — funciona pros dois tipos (date '2026-07-01'::text = '2026-07-01'
-- e text já no formato). Testado sem erro; billing de julho re-completado (285/285).
-- Capturado via pg_get_functiondef (repo == banco).

CREATE OR REPLACE FUNCTION public.ml_edge_passo(p_modo text, p_sub_type text DEFAULT NULL::text, p_tabela text DEFAULT NULL::text, p_tentativas integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_res jsonb; v_http int; v_erro text; i int;
  v_k0 text; v_k1 text; v_t0 int; v_t1 int; v_total_api int; v_no_banco int;
  v_completo boolean := NULL; v_hoje date;
BEGIN
  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  v_k0 := to_char(v_hoje, 'YYYY-MM-01');
  v_k1 := to_char((v_hoje - interval '1 month')::date, 'YYYY-MM-01');

  FOR i IN 1..p_tentativas LOOP
    v_res  := ml_edge_call(jsonb_build_object('modo', p_modo));
    v_http := (v_res->>'http_status')::int;
    v_erro := v_res->'body'->>'detalhe';

    IF v_http = 200 THEN
      -- 200 não garante completo: a API trunca em silêncio. Confere quando dá.
      IF p_tabela IS NULL OR p_sub_type IS NULL THEN
        RETURN jsonb_build_object('completo', true, 'http_status', v_http,
          'tentativas', i, 'verificado', false, 'resposta', v_res);
      END IF;
      v_t0 := public.ml_api_total(p_sub_type, v_k0);
      v_t1 := public.ml_api_total(p_sub_type, v_k1);
      IF v_t0 IS NULL AND v_t1 IS NULL THEN
        -- não deu pra verificar (API fora): não mente dizendo completo.
        RETURN jsonb_build_object('completo', true, 'http_status', v_http,
          'tentativas', i, 'verificado', false,
          'aviso', 'API nao respondeu a verificacao de total', 'resposta', v_res);
      END IF;
      v_total_api := coalesce(v_t0,0) + coalesce(v_t1,0);
      EXECUTE format(
        'select count(*) from public.%I where periodo_key::text in ($1,$2)', p_tabela)
        INTO v_no_banco USING v_k0, v_k1;
      v_completo := v_no_banco >= v_total_api;
      IF v_completo THEN
        RETURN jsonb_build_object('completo', true, 'http_status', v_http, 'tentativas', i,
          'verificado', true, 'no_banco', v_no_banco, 'total_api', v_total_api);
      END IF;
      -- incompleto: re-tenta o walk (a Edge é idempotente por detail_id)
      v_erro := format('INCOMPLETO: %s de %s (API truncou)', v_no_banco, v_total_api);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('completo', coalesce(v_completo,false), 'http_status', v_http,
    'tentativas', p_tentativas, 'verificado', (v_completo IS NOT NULL),
    'no_banco', v_no_banco, 'total_api', v_total_api,
    'erro', coalesce(v_erro, 'HTTP '||coalesce(v_http::text,'?')));
END $function$;
