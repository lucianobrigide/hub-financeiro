-- Frete Flex: competência por quinzena (regra do Luciano, 05/08/2026).
--
-- As transportadoras do Flex (J3 Flex etc.) faturam por quinzena:
--   "1ª QZ ..." — emitida ~dia 16-20, refere-se à 1ª quinzena do PRÓPRIO mês
--                 → competência = data da NF (regra padrão, nada muda).
--   "2ª QZ ..." — emitida no início do mês SEGUINTE, refere-se à 2ª quinzena
--                 do mês ANTERIOR → competência = data da NF − 1 mês.
-- Exemplos validados com o Luciano: 2ª QZ 0000089801 (01/06)→maio;
-- 2ª QZ NF 00108913 (01/07)→junho; 2ª QZ 0000133255 (01/08)→julho.
-- Escopo: lançamentos do projeto "Fretes Flex" (11028072487) com documento
-- começando por "2ª". Demais lançamentos seguem a régua padrão.

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
            -- Frete Flex, NF de 2ª quinzena: competência = mês anterior à emissão
            WHEN omie_despesas.raw ->> 'codigo_projeto'::text = '11028072487'::text
                 AND COALESCE(omie_despesas.raw ->> 'numero_documento'::text, ''::text) LIKE '2ª%'
            THEN (COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento) - '1 mon'::interval)::date
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
