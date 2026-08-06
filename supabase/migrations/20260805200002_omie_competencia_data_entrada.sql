-- Competência padrão do AP = data_entrada da Omie (Luciano, 05/08/2026).
--
-- DESCOBERTA: a Omie registra a competência do documento em `data_entrada`
-- (ex.: NF Meta "FACE 141330233" emitida 03/07 com entrada 30/06 = junho), e o
-- Hub usava a EMISSÃO — errando o mês de forma sistemática: todo mês há 14-19
-- boletos (~R$ 35-58k) emitidos no dia 1º que pertencem ao mês anterior, e um
-- contrato com 13 parcelas de R$ 5.000 (R$ 65k) caía inteiro em junho pela
-- emissão quando a entrada espalha mensalmente até set/2027.
--
-- RÉGUA NOVA (ramo AP): competência = data_entrada; fallback emissão; fallback
-- vencimento. As regras específicas continuam PREVALECENDO sobre a entrada:
--   1. PIS/COFINS (2.06.03/04): vencimento − 1 mês (inalterada);
--   2. Frete Flex (projeto 11028072487): quinzena — "2ª QZ" = emissão − 1 mês,
--      "1ª QZ" = emissão (a entrada da Omie DISCORDA da régua do Luciano em
--      pelo menos um título: 1ª QZ 0000097400, 1ª quinzena de julho, entrada
--      30/06 — a régua dita por ele domina);
--   3. Parcelamento DIFAL BA (fornecedor 10705160510): vencimento (a entrada
--      das parcelas está toda no lançamento da renegociação, inútil);
--   4. Fornecedor 11244916229, parcelas >1: vencimento (inalterada).

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
            -- Frete Flex: quinzena (regra do Luciano prevalece sobre a entrada)
            WHEN omie_despesas.raw ->> 'codigo_projeto'::text = '11028072487'::text
                 AND COALESCE(omie_despesas.raw ->> 'numero_documento'::text, ''::text) LIKE '2ª%'
            THEN (COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento) - '1 mon'::interval)::date
            WHEN omie_despesas.raw ->> 'codigo_projeto'::text = '11028072487'::text
            THEN COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento)
            -- Parcelamento DIFAL BA (59x até 2031): competência = vencimento
            WHEN omie_despesas.codigo_cliente_fornecedor = '10705160510'::bigint THEN COALESCE(omie_despesas.data_vencimento, omie_despesas.data_emissao)
            WHEN omie_despesas.codigo_cliente_fornecedor = '11244916229'::bigint AND NULLIF(split_part(COALESCE(omie_despesas.raw ->> 'numero_parcela'::text, ''::text), '/'::text, 2), ''::text) ~ '^\d+$'::text AND split_part(omie_despesas.raw ->> 'numero_parcela'::text, '/'::text, 2)::integer > 1 THEN omie_despesas.data_vencimento
            -- RÉGUA PADRÃO: competência da Omie (data_entrada), fallback emissão/vencimento
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
