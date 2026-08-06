-- DIFAL BA sem categoria assume 2.06.94 → I1 restaurado em junho (Luciano, 05/08/2026).
--
-- HISTÓRICO: o DRE de junho tinha o "DIFAL por fora" de R$ 16.000 (entrada paga
-- em 11/06). Na renegociação do débito com a BA, a Omie re-lançou o parcelamento
-- (entrada + 59 parcelas) SEM categoria — e o re-sync sobrescreveu, derrubando o
-- valor de junho do I1. O fornecedor "ICMS" (10705160510) é usado só para o
-- DIFAL BA: 17 títulos históricos categorizados 2.06.94 (I1, ok) + 1 título
-- 2.06.90 (DIFAL de plataforma, excluído, ok) + 60 sem categoria (parcelamento).
--
-- REGRA: lançamento DESSE fornecedor sem categoria assume '2.06.94' (DIFAL por
-- fora → I1). Combinada com a regra de competência já existente (vencimento,
-- 20260805160002): entrada em junho (11/06), nada em julho (parcela 2 postergada),
-- parcelas mensais de 20/08/2026 em diante — exatamente a régua do Luciano.
-- Títulos com categoria preenchida (2.06.90/2.06.94) não são tocados.

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
            -- Parcelamento DIFAL BA (59x até 2031): competência = vencimento
            WHEN omie_despesas.codigo_cliente_fornecedor = '10705160510'::bigint THEN COALESCE(omie_despesas.data_vencimento, omie_despesas.data_emissao)
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
