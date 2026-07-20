-- Segunda fonte de despesas: movimentos de conta corrente (pagamentos DIRETOS, fora do
-- Contas a Pagar) — ex.: Uber, motoboys, autoelétrica. Só o grupo CONTA_CORRENTE_PAG
-- (têm categoria cCodCateg e projeto cCodProjeto, então encaixam no mesmo de-para do DRE).
--
-- ATENÇÃO (dedup): grande parte desses movimentos DUPLICA títulos do AP (o mesmo gasto é
-- lançado como conta a pagar E importado do extrato). Não há vínculo duro (nCodTitulo=0),
-- então o consumo no DRE precisa deduplicar por (fornecedor + valor + competência) e só
-- somar os movimentos que NÃO têm AP equivalente. Ver RPC de consumo.
CREATE TABLE IF NOT EXISTS public.omie_mov_cc (
  n_cod_mov_cc      bigint PRIMARY KEY,
  n_cod_cliente     bigint,
  codigo_categoria  text,
  codigo_projeto    text,
  valor             numeric(14,2),
  data_pagamento    date,
  c_grupo           text,
  c_natureza        text,
  c_status          text,
  raw               jsonb NOT NULL,
  ingested_at       timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.omie_mov_cc ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.omie_mov_cc TO service_role;
CREATE INDEX IF NOT EXISTS omie_mov_cc_pag_idx ON public.omie_mov_cc(data_pagamento);

-- Ingestão: varre páginas [p_de..p_ate] de ListarMovimentos e grava só CONTA_CORRENTE_PAG.
-- (nRegPorPagina é capado em ~100 pela Omie → ~141 páginas no total; rodar em lotes.)
CREATE OR REPLACE FUNCTION public.omie_fill_movimentos(p_de int, p_ate int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions'
AS $function$
DECLARE
  v_key text; v_sec text; p int; resp jsonb; v_tot_pag int := NULL;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name='omie_app_key';
  SELECT decrypted_secret INTO v_sec FROM vault.decrypted_secrets WHERE name='omie_app_secret';
  FOR p IN p_de..p_ate LOOP
    resp := (extensions.http_post('https://app.omie.com.br/api/v1/financas/mf/',
      jsonb_build_object('call','ListarMovimentos','app_key',v_key,'app_secret',v_sec,
        'param',jsonb_build_array(jsonb_build_object('nPagina',p,'nRegPorPagina',500)))::text,
      'application/json')).content::jsonb;
    v_tot_pag := (resp->>'nTotPaginas')::int;
    INSERT INTO public.omie_mov_cc AS t
      (n_cod_mov_cc, n_cod_cliente, codigo_categoria, codigo_projeto, valor, data_pagamento, c_grupo, c_natureza, c_status, raw, updated_at)
    SELECT DISTINCT ON (mov)
      mov, nullif(d->>'nCodCliente','')::bigint, d->>'cCodCateg',
      nullif(d->>'cCodProjeto',''), coalesce((d->>'nValorMovCC')::numeric,0),
      to_date(nullif(d->>'dDtPagamento',''),'DD/MM/YYYY'), d->>'cGrupo', d->>'cNatureza', d->>'cStatus', m, now()
    FROM jsonb_array_elements(resp->'movimentos') m,
      lateral (SELECT m->'detalhes' AS d, (m->'detalhes'->>'nCodMovCC')::bigint AS mov) x
    WHERE d->>'cGrupo' = 'CONTA_CORRENTE_PAG' AND (d->>'nCodMovCC') IS NOT NULL AND (d->>'nCodMovCC') <> '0'
    ORDER BY mov
    ON CONFLICT (n_cod_mov_cc) DO UPDATE SET
      codigo_categoria=excluded.codigo_categoria, codigo_projeto=excluded.codigo_projeto, valor=excluded.valor,
      data_pagamento=excluded.data_pagamento, c_status=excluded.c_status, raw=excluded.raw, updated_at=now();
    EXIT WHEN p >= v_tot_pag;
  END LOOP;
  RETURN jsonb_build_object('total_paginas', v_tot_pag, 'mov_cc_no_banco', (SELECT count(*) FROM public.omie_mov_cc));
END $function$;
GRANT EXECUTE ON FUNCTION public.omie_fill_movimentos(int,int) TO service_role;
