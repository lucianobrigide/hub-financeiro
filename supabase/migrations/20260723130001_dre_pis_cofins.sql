-- PIS/COFINS (impostos sobre a receita) no DRE, como filhos de "Impostos s/ Vendas"
-- (acima da Margem de Contribuição), ao lado de DIFAL/IPI. (Luciano, 23/07/2026.)
--   * PIS   = categoria Omie 2.06.03 -> linha I3
--   * COFINS= categoria Omie 2.06.04 -> linha I4
-- Competência: imposto sobre receita compete ao mês do fato gerador = mês do VENCIMENTO − 1
--   (vencem dia 25 do mês seguinte). Sem isso cairiam no mês da emissão (mês seguinte).
-- Projeto: os lançamentos vêm com o projeto "Impostos s/ Vendas" (10704266416 -> I1), que no
--   RPC tem precedência sobre a categoria e jogaria tudo em I1 (DIFAL). Por isso a view ANULA
--   o projeto só para 2.06.03/2.06.04, deixando a categoria (I3/I4) valer.
-- OBS: as linhas PIS/COFINS chegam via omie_despesas (sync da Omie). O sync incremental ainda é
--   manual (Etapa 5) — enquanto isso, o backfill mensal depende do sync rodar.

INSERT INTO public.omie_dre_mapa (codigo_categoria, dre_code, dre_label, incluir, categoria_nome, obs) VALUES
 ('2.06.03','I3','PIS',   true,'PIS',   'Imposto sobre receita (PIS). Competência = mês do vencimento − 1 (vence dia 25 do mês seguinte).'),
 ('2.06.04','I4','COFINS',true,'COFINS','Imposto sobre receita (COFINS). Competência = mês do vencimento − 1.')
ON CONFLICT (codigo_categoria) DO UPDATE SET dre_code=EXCLUDED.dre_code, dre_label=EXCLUDED.dre_label,
  incluir=EXCLUDED.incluir, categoria_nome=EXCLUDED.categoria_nome, obs=EXCLUDED.obs;

CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
 SELECT omie_despesas.codigo_categoria,
    CASE WHEN omie_despesas.codigo_categoria IN ('2.06.03','2.06.04') THEN NULL
         ELSE omie_despesas.raw ->> 'codigo_projeto'::text END AS codigo_projeto,
    omie_despesas.valor,
        CASE
            WHEN omie_despesas.codigo_categoria IN ('2.06.03','2.06.04')
                 THEN (date_trunc('month', COALESCE(omie_despesas.data_vencimento, omie_despesas.data_emissao)) - interval '1 month')::date
            WHEN omie_despesas.codigo_cliente_fornecedor = '11244916229'::bigint AND NULLIF(split_part(COALESCE(omie_despesas.raw ->> 'numero_parcela'::text, ''::text), '/'::text, 2), ''::text) ~ '^\d+$'::text AND split_part(omie_despesas.raw ->> 'numero_parcela'::text, '/'::text, 2)::integer > 1 THEN omie_despesas.data_vencimento
            ELSE COALESCE(omie_despesas.data_emissao, omie_despesas.data_vencimento)
        END AS competencia_data,
    omie_despesas.status_titulo <> 'CANCELADO'::text AS valido,
    omie_despesas.codigo_cliente_fornecedor AS fornecedor_cod,
    omie_despesas.raw ->> 'numero_documento'::text AS doc,
    'AP'::text AS fonte
   FROM omie_despesas
UNION ALL
 SELECT mc.codigo_categoria, mc.codigo_projeto, mc.valor, mc.data_pagamento AS competencia_data,
    mc.c_status <> 'CANCELADO'::text AS valido, mc.n_cod_cliente AS fornecedor_cod,
    (mc.raw -> 'detalhes'::text) ->> 'cNumTitulo'::text AS doc, 'CC'::text AS fonte
   FROM omie_mov_cc mc
  WHERE COALESCE(mc.n_cod_titulo, 0::bigint) = 0 AND NOT (EXISTS ( SELECT 1
           FROM omie_forn_plataforma p WHERE p.codigo_cliente = mc.n_cod_cliente))
UNION ALL
 SELECT 'ML.FATURA'::text, NULL::text, ft.valor::numeric(14,2), ft.competencia_data,
    true, 999000001::bigint, ft.descricao, 'ML'::text
   FROM public.ml_fatura_tarifas ft
  WHERE ft.valor <> 0;
