-- Omie: soft-delete de títulos órfãos (conferência do DRE, 05/08/2026).
--
-- PROBLEMA: omie_fill_despesas só insere/atualiza (upsert) — título excluído ou
-- re-lançado na Omie (baixa que recria o lançamento com outro id, renegociação
-- em parcelamento) fica órfão no banco e segue contando no DRE para sempre.
-- Auditoria de 05/08: 84 órfãos, R$ 28.060 contando indevidamente no DRE de
-- julho (I1 R$ 23.000 — DIFAL BA e IPI renegociados; C5/C1/R4 menores).
--
-- FIX (sem apagar nada — auditável):
--   1. Coluna `ausente_desde`: quando o título some da API, o sync carimba a
--      data em vez de deletar. Se reaparecer, o upsert limpa o carimbo.
--   2. View omie_dre_lancamentos ignora títulos com ausente_desde preenchido.
-- Backfill: a primeira execução de omie_fill_despesas() após esta migration
-- carimba os 84 órfãos atuais (updated_at antigo).

ALTER TABLE public.omie_despesas ADD COLUMN IF NOT EXISTS ausente_desde timestamptz;
COMMENT ON COLUMN public.omie_despesas.ausente_desde IS
  'Título deixou de ser retornado pela ListarContasPagar nesta data (excluído/re-lançado na Omie). NULL = vivo. A view omie_dre_lancamentos ignora não-nulos.';

CREATE OR REPLACE FUNCTION public.omie_fill_despesas()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
 SET statement_timeout TO '280s'
AS $function$
DECLARE v_key text; v_sec text; p int := 1; resp jsonb; v_tot int := NULL; v_lidos int := 0;
        v_inicio timestamptz := now(); v_orfaos int;
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
       raw=excluded.raw, updated_at=now(),
       ausente_desde=NULL;  -- reapareceu na API: volta a valer
    v_lidos := v_lidos + jsonb_array_length(coalesce(resp->'conta_pagar_cadastro','[]'::jsonb));
    EXIT WHEN p >= v_tot;
    p := p + 1;
    PERFORM pg_sleep(0.25);
  END LOOP;

  -- Órfãos: não vieram em nenhuma página desta varredura completa (updated_at
  -- não foi tocado). Carimba a ausência; nunca deleta.
  UPDATE public.omie_despesas
     SET ausente_desde = coalesce(ausente_desde, now())
   WHERE updated_at < v_inicio AND ausente_desde IS NULL;
  GET DIAGNOSTICS v_orfaos = ROW_COUNT;

  RETURN jsonb_build_object('paginas', p, 'total_paginas', v_tot, 'lidos', v_lidos,
    'orfaos_marcados', v_orfaos,
    'orfaos_total', (SELECT count(*) FROM public.omie_despesas WHERE ausente_desde IS NOT NULL),
    'ap_no_banco', (SELECT count(*) FROM public.omie_despesas));
END $function$;

-- View: ramo AP ignora órfãos (CC e ML.FATURA inalterados)
CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
 SELECT omie_despesas.codigo_categoria,
        CASE
            WHEN omie_despesas.codigo_categoria = ANY (ARRAY['2.06.03'::text, '2.06.04'::text]) THEN NULL::text
            ELSE omie_despesas.raw ->> 'codigo_projeto'::text
        END AS codigo_projeto,
    omie_despesas.valor,
        CASE
            WHEN omie_despesas.codigo_categoria = ANY (ARRAY['2.06.03'::text, '2.06.04'::text]) THEN (date_trunc('month'::text, COALESCE(omie_despesas.data_vencimento, omie_despesas.data_emissao)::timestamp with time zone) - '1 mon'::interval)::date
            WHEN omie_despesas.codigo_cliente_fornecedor = '11244916229'::bigint AND NULLIF(split_part(COALESCE(omie_despesas.raw ->> 'numero_parcela'::text, ''::text), '/'::text, 2), ''::text) ~ '^\d+$'::text AND split_part(omie_despesas.raw ->> 'numero_parcela'::text, '/'::text, 2)::integer > 1 THEN omie_despesas.data_vencimento
            ELSE COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento)
        END AS competencia_data,
    omie_despesas.status_titulo <> 'CANCELADO'::text AS valido,
    omie_despesas.codigo_cliente_fornecedor AS fornecedor_cod,
    omie_despesas.raw ->> 'numero_documento'::text AS doc,
    'AP'::text AS fonte
   FROM omie_despesas
  WHERE omie_despesas.ausente_desde IS NULL
UNION ALL
 SELECT mc.codigo_categoria,
    mc.codigo_projeto,
    mc.valor,
    mc.data_pagamento AS competencia_data,
    mc.c_status <> 'CANCELADO'::text AS valido,
    mc.n_cod_cliente AS fornecedor_cod,
    (mc.raw -> 'detalhes'::text) ->> 'cNumTitulo'::text AS doc,
    'CC'::text AS fonte
   FROM omie_mov_cc mc
  WHERE COALESCE(mc.n_cod_titulo, 0::bigint) = 0 AND NOT (EXISTS ( SELECT 1
           FROM omie_forn_plataforma p
          WHERE p.codigo_cliente = mc.n_cod_cliente))
UNION ALL
 SELECT 'ML.FATURA'::text AS codigo_categoria,
    NULL::text AS codigo_projeto,
    ft.valor::numeric(14,2) AS valor,
    ft.competencia_data,
    true AS valido,
    999000001::bigint AS fornecedor_cod,
    ft.descricao AS doc,
    'ML'::text AS fonte
   FROM ml_fatura_tarifas ft
  WHERE ft.valor <> 0::numeric;
