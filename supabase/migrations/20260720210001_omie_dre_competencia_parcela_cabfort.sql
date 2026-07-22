-- Competência: regra geral = emissão (fallback vencimento). EXCEÇÃO pontual (decisão do
-- Luciano): as parcelas (MMM>1) da CABFORT (fornecedor 11244916229) usam VENCIMENTO — cada
-- parcela cai no mês em que é paga, não tudo na emissão de 12/06. Aplicado SÓ à CABFORT,
-- não a todo parcelamento. (Se surgirem mais casos, vale trocar por uma tabela de config.)
CREATE OR REPLACE VIEW public.omie_dre_lancamentos AS
  SELECT codigo_categoria,
         raw->>'codigo_projeto' AS codigo_projeto,
         valor,
         CASE
           WHEN codigo_cliente_fornecedor = 11244916229
                AND nullif(split_part(coalesce(raw->>'numero_parcela',''),'/',2),'') ~ '^\d+$'
                AND split_part(raw->>'numero_parcela','/',2)::int > 1
           THEN data_vencimento
           ELSE COALESCE(data_emissao, data_vencimento)
         END AS competencia_data,
         (status_titulo <> 'CANCELADO') AS valido,
         codigo_cliente_fornecedor AS fornecedor_cod,
         raw->>'numero_documento' AS doc,
         'AP'::text AS fonte
  FROM public.omie_despesas
  UNION ALL
  SELECT codigo_categoria, codigo_projeto, valor,
         data_pagamento, (c_status <> 'CANCELADO'),
         n_cod_cliente, raw->'detalhes'->>'cNumTitulo', 'CC'::text
  FROM public.omie_mov_cc mc
  WHERE COALESCE(mc.n_cod_titulo, 0) = 0
    AND NOT EXISTS (SELECT 1 FROM public.omie_forn_plataforma p WHERE p.codigo_cliente = mc.n_cod_cliente);
