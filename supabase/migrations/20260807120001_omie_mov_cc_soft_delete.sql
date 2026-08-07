-- Soft-delete de movimentos da conta corrente (mesmo padrão do AP, 20260805160001).
--
-- INCIDENTE 07/08: a Fernanda refez os pagamentos das NFs 14/15 da GDB na Omie
-- (removeu 2× R$ 3.499,40 duplicados e redirecionou R$ 93.001,20 da NF 14 para a
-- NF 15) — e os movimentos antigos ficaram FANTASMAS em omie_mov_cc, porque o
-- sync só faz upsert. Hoje sem impacto no DRE (eram atrelados a título, e o ramo
-- CC da view só lê avulsos), mas um AVULSO apagado na Omie contaria pra sempre.
--
-- FIX:
--   1. Coluna ausente_desde em omie_mov_cc (nunca deleta; carimba).
--   2. omie_fill_movimentos marca como ausentes os movimentos DENTRO DA JANELA
--      varrida que não vieram — somente quando a varredura foi COMPLETA
--      (começou na página 1 e alcançou a última), para nunca marcar por
--      varredura parcial. Se o movimento reaparecer, o upsert desmarca.
--   3. View omie_dre_lancamentos: ramo CC ignora ausentes.

ALTER TABLE public.omie_mov_cc ADD COLUMN IF NOT EXISTS ausente_desde timestamptz;
COMMENT ON COLUMN public.omie_mov_cc.ausente_desde IS
  'Movimento deixou de ser retornado pela ListarMovimentos numa varredura completa da sua janela (excluído/refeito na Omie). NULL = vivo. O ramo CC da omie_dre_lancamentos ignora não-nulos.';

CREATE OR REPLACE FUNCTION public.omie_fill_movimentos(p_de integer, p_ate integer, p_dt_de date DEFAULT NULL::date, p_dt_ate date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_key text; v_sec text; p int; resp jsonb; v_tot_pag int := NULL; v_param jsonb;
  v_inicio timestamptz := now(); v_ausentes int := 0; v_pag int := 0;
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
      valor=excluded.valor, data_pagamento=excluded.data_pagamento, c_status=excluded.c_status, raw=excluded.raw, updated_at=now(),
      ausente_desde=NULL;  -- reapareceu na API: volta a valer
    v_pag := p;
    EXIT WHEN p >= v_tot_pag;
  END LOOP;

  -- Só carimba ausência se a varredura da janela foi COMPLETA (página 1 até a última)
  IF p_de = 1 AND v_pag >= v_tot_pag THEN
    UPDATE public.omie_mov_cc
       SET ausente_desde = coalesce(ausente_desde, now())
     WHERE updated_at < v_inicio AND ausente_desde IS NULL
       AND (p_dt_de  IS NULL OR data_pagamento >= p_dt_de)
       AND (p_dt_ate IS NULL OR data_pagamento <= p_dt_ate);
    GET DIAGNOSTICS v_ausentes = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('ultima_pagina', v_pag, 'total_paginas', v_tot_pag,
    'ausentes_marcados', v_ausentes,
    'mov_cc_no_banco', (SELECT count(*) FROM public.omie_mov_cc));
END $function$;

-- View: ramo CC ignora movimentos ausentes
CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
 SELECT
        CASE
            WHEN omie_despesas.codigo_categoria IS NULL AND omie_despesas.codigo_cliente_fornecedor = '10705160510'::bigint
            THEN '2.06.94'::text
            ELSE omie_despesas.codigo_categoria
        END AS codigo_categoria,
        CASE
            WHEN omie_despesas.codigo_categoria = ANY (ARRAY['2.06.03'::text, '2.06.04'::text]) THEN NULL::text
            ELSE omie_despesas.raw ->> 'codigo_projeto'::text
        END AS codigo_projeto,
    omie_despesas.valor,
        CASE
            WHEN omie_despesas.codigo_categoria = ANY (ARRAY['2.06.03'::text, '2.06.04'::text]) THEN (date_trunc('month'::text, COALESCE(omie_despesas.data_vencimento, omie_despesas.data_emissao)::timestamp with time zone) - '1 mon'::interval)::date
            WHEN omie_despesas.raw ->> 'codigo_projeto'::text = '11028072487'::text
                 AND COALESCE(omie_despesas.raw ->> 'numero_documento'::text, ''::text) LIKE '2ª%'
            THEN (COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento) - '1 mon'::interval)::date
            WHEN omie_despesas.raw ->> 'codigo_projeto'::text = '11028072487'::text
            THEN COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento)
            WHEN omie_despesas.codigo_cliente_fornecedor = '10705160510'::bigint THEN COALESCE(omie_despesas.data_vencimento, omie_despesas.data_emissao)
            WHEN omie_despesas.codigo_cliente_fornecedor = '11244916229'::bigint AND NULLIF(split_part(COALESCE(omie_despesas.raw ->> 'numero_parcela'::text, ''::text), '/'::text, 2), ''::text) ~ '^\d+$'::text AND split_part(omie_despesas.raw ->> 'numero_parcela'::text, '/'::text, 2)::integer > 1 THEN omie_despesas.data_vencimento
            ELSE COALESCE(to_date(NULLIF(omie_despesas.raw ->> 'data_entrada'::text, ''::text), 'DD/MM/YYYY'::text),
                          omie_despesas.data_emissao, omie_despesas.data_vencimento)
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
  WHERE COALESCE(mc.n_cod_titulo, 0::bigint) = 0
    AND mc.ausente_desde IS NULL
    AND NOT (EXISTS ( SELECT 1
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
