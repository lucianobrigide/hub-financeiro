-- Pluga ml_fatura_tarifas no DRE: categoria sintética -> R6 (Fixo_Outros), fornecedor legível
-- para o drill-down, e 3º UNION na view omie_dre_lancamentos (as RPCs do DRE leem dela).
-- Fica SÓ no DRE (não vai para o Hub da plataforma). (Luciano, 22/07/2026.)

INSERT INTO public.omie_dre_mapa (codigo_categoria, dre_code, dre_label, incluir, categoria_nome, obs)
VALUES ('ML.FATURA','R6','Fixo_Outros',true,'Tarifas ML (fatura)',
        'Tarifas cobradas na fatura do ML (vencimento) não capturadas por venda/ADS/Full: Assessoria comercial (CPAC) e Minha página (CESM). Fonte: ml_fatura_tarifas.')
ON CONFLICT (codigo_categoria) DO UPDATE SET dre_code=EXCLUDED.dre_code, dre_label=EXCLUDED.dre_label,
  incluir=EXCLUDED.incluir, categoria_nome=EXCLUDED.categoria_nome, obs=EXCLUDED.obs;

-- Fornecedor sintético para o drill-down (nível 3) mostrar nome legível.
INSERT INTO public.omie_fornecedores (codigo_cliente, razao_social, updated_at)
VALUES (999000001,'Mercado Livre — Fatura', now())
ON CONFLICT (codigo_cliente) DO UPDATE SET razao_social=EXCLUDED.razao_social;

-- View de lançamentos do DRE: AP (Omie) + CC genuíno (Omie) + ML fatura (novo 3º UNION).
CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
 SELECT omie_despesas.codigo_categoria,
    omie_despesas.raw ->> 'codigo_projeto'::text AS codigo_projeto,
    omie_despesas.valor,
        CASE
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
 SELECT 'ML.FATURA'::text AS codigo_categoria, NULL::text AS codigo_projeto,
    ft.valor::numeric(14,2) AS valor, ft.competencia_data,
    true AS valido, 999000001::bigint AS fornecedor_cod,
    ft.descricao AS doc, 'ML'::text AS fonte
   FROM public.ml_fatura_tarifas ft
  WHERE ft.valor <> 0;
