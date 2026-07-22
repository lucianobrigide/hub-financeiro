-- Segunda fonte de despesas: movimentos de conta corrente (pagamentos DIRETOS, fora do
-- Contas a Pagar) — ex.: Uber, motoboys. Só o grupo CONTA_CORRENTE_PAG.
-- Dedup EXATA pelo vínculo de título: n_cod_titulo=0 = pagamento direto genuíno;
-- n_cod_titulo<>0 = baixa de um título que já está no AP (não conta de novo).
CREATE TABLE IF NOT EXISTS public.omie_mov_cc (
  n_cod_mov_cc      bigint PRIMARY KEY,
  n_cod_cliente     bigint,
  n_cod_titulo      bigint,          -- id do título de AP vinculado (0 = pagamento direto)
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
      (n_cod_mov_cc, n_cod_cliente, n_cod_titulo, codigo_categoria, codigo_projeto, valor, data_pagamento, c_grupo, c_natureza, c_status, raw, updated_at)
    SELECT (d->>'nCodMovCC')::bigint, nullif(d->>'nCodCliente','')::bigint, nullif(d->>'nCodTitulo','')::bigint, d->>'cCodCateg',
      nullif(d->>'cCodProjeto',''), (d->>'nValorMovCC')::numeric,
      to_date(nullif(d->>'dDtPagamento',''),'DD/MM/YYYY'), d->>'cGrupo', d->>'cNatureza', d->>'cStatus', m, now()
    FROM jsonb_array_elements(resp->'movimentos') m, lateral (SELECT m->'detalhes' AS d) x
    WHERE m->'detalhes'->>'cGrupo' = 'CONTA_CORRENTE_PAG'
    ON CONFLICT (n_cod_mov_cc) DO UPDATE SET
      n_cod_titulo=excluded.n_cod_titulo, codigo_categoria=excluded.codigo_categoria, codigo_projeto=excluded.codigo_projeto,
      valor=excluded.valor, data_pagamento=excluded.data_pagamento, c_status=excluded.c_status, raw=excluded.raw, updated_at=now();
    EXIT WHEN p >= v_tot_pag;
  END LOOP;
  RETURN jsonb_build_object('ultima_pagina', p, 'total_paginas', v_tot_pag, 'mov_cc_no_banco', (SELECT count(*) FROM public.omie_mov_cc));
END $function$;
GRANT EXECUTE ON FUNCTION public.omie_fill_movimentos(int,int) TO service_role;
