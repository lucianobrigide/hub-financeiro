-- Trava de fechamento do DRE (decisão Luciano, 10/08/2026).
--
-- INCIDENTE: julho foi batido com o financeiro em 07/08 e, dias depois, uma
-- remarcação na Omie (NF 15 GDB recebeu projeto de baixa indevido) tirou
-- R$ 94,9k do R3 silenciosamente. Mês fechado não tinha proteção nenhuma —
-- o Hub espelha a Omie, como deve, mas ninguém ficava sabendo do drift.
--
-- A TRAVA:
--   omie_dre_fechar_mes(mes, obs)  → congela o estado vivo (grupo_r + detalhe)
--                                    como fechamento oficial do mês.
--   omie_dre_drift(mes)            → compara o vivo com o congelado, linha a
--                                    linha (e categoria a categoria), e devolve
--                                    os deltas. Drift = alguém remarcou o
--                                    passado na Omie depois do fechamento.
-- Re-fechar um mês substitui o snapshot (aceitação consciente do novo número).
-- Nada muda no cálculo vivo do DRE — a trava é um espelho de auditoria.

CREATE TABLE IF NOT EXISTS public.omie_dre_fechamentos (
  mes text PRIMARY KEY,                       -- 'YYYY-MM'
  fechado_em timestamptz NOT NULL DEFAULT now(),
  grupo_r jsonb NOT NULL,                     -- snapshot de omie_dre_grupo_r(mes)
  detalhe jsonb NOT NULL,                     -- snapshot de omie_dre_grupo_r_detalhe(mes)
  obs text
);
ALTER TABLE public.omie_dre_fechamentos ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.omie_dre_fechamentos IS
  'Fechamentos oficiais do DRE (Grupo R + impostos via Omie). Snapshot congelado no ato do fechamento; omie_dre_drift() acusa qualquer divergência posterior.';

CREATE OR REPLACE FUNCTION public.omie_dre_fechar_mes(p_month text, p_obs text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_grupo jsonb; v_det jsonb;
BEGIN
  v_grupo := public.omie_dre_grupo_r(p_month);
  v_det   := public.omie_dre_grupo_r_detalhe(p_month);
  INSERT INTO public.omie_dre_fechamentos (mes, fechado_em, grupo_r, detalhe, obs)
  VALUES (p_month, now(), v_grupo, v_det, p_obs)
  ON CONFLICT (mes) DO UPDATE SET fechado_em = now(), grupo_r = excluded.grupo_r,
    detalhe = excluded.detalhe, obs = excluded.obs;
  RETURN jsonb_build_object('mes', p_month, 'fechado_em', now(), 'linhas', (SELECT count(*) FROM jsonb_object_keys(v_grupo)));
END $function$;

CREATE OR REPLACE FUNCTION public.omie_dre_drift(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH f AS (SELECT * FROM public.omie_dre_fechamentos WHERE mes = p_month),
  vivo AS (SELECT public.omie_dre_grupo_r(p_month) AS g),
  linhas AS (
    SELECT COALESCE(a.key, b.key) AS dre_code,
           COALESCE((a.value)::numeric, 0) AS fechado,
           COALESCE((b.value)::numeric, 0) AS atual
    FROM (SELECT key, value FROM f, jsonb_each_text(f.grupo_r)) a
    FULL OUTER JOIN (SELECT key, value FROM vivo, jsonb_each_text(vivo.g)) b ON b.key = a.key
  )
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM f) THEN jsonb_build_object('mes', p_month, 'fechado', false)
    ELSE jsonb_build_object(
      'mes', p_month, 'fechado', true,
      'fechado_em', (SELECT to_char(fechado_em AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI') FROM f),
      'obs', (SELECT obs FROM f),
      'drift_total', COALESCE((SELECT round(sum(atual - fechado), 2) FROM linhas), 0),
      'linhas_divergentes', COALESCE((SELECT jsonb_agg(jsonb_build_object(
          'linha', dre_code, 'fechado', fechado, 'atual', atual, 'delta', round(atual - fechado, 2))
          ORDER BY abs(atual - fechado) DESC)
        FROM linhas WHERE round(atual - fechado, 2) <> 0), '[]'::jsonb))
  END;
$function$;
