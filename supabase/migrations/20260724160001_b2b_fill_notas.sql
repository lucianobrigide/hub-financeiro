-- Ingestão das notas B2B/diretas do Tiny (canal B2B). (Luciano, 24/07/2026.)
-- O /notas do Tiny devolve TODAS as NFs (22k+/mês — cada pedido de marketplace vira NF).
-- Discriminadores das notas do canal B2B:
--   1) `ecommerce.nome` VAZIO (não-marketplace; as de ML/Shopee/TikTok/Amazon têm nome preenchido)
--   2) `tipo` = 'S' (saída)
--   3) `naturezaOperacao` começa com "Venda" — exclui "Devolução de Compra" (série 11, ARNIX) e
--      "Remessa para bonificação/doação/brinde" (série 13), que também são ecommerce-vazio+S mas
--      NÃO são receita. (Sem esse filtro, jul/26 dava R$327k falso; correto = R$15k.)
-- Inclui: B2B real (série 7), venda a colaborador (série 15), venda não-contribuinte direta.
-- Como o Tiny NÃO filtra por canal/natureza no servidor, varre o mês inteiro filtrando client-side.
-- Batched por offset (p_off_start, p_max_pages) porque são ~227 páginas/mês. natureza da nota =
-- naturezaOperacao do 1º item; itens: DELETE+INSERT por nota_id.
CREATE OR REPLACE FUNCTION public.b2b_fill_notas(p_de text, p_ate text, p_off_start int DEFAULT 0, p_max_pages int DEFAULT 40)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions' SET statement_timeout TO '160s'
AS $function$
DECLARE v_tok text; v_off int; v_total int := NULL; v_body jsonb; v_id bigint; v_det jsonb; v_nat text;
        v_n int := 0; v_scanned int := 0; v_cnt int; v_pg int := 0; v_fim bool := false;
BEGIN
  v_off := p_off_start;
  SELECT to_jsonb(tiny_get_state())->>'access_token' INTO v_tok;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','20000');
  LOOP
    v_pg := v_pg + 1;
    EXIT WHEN v_pg > p_max_pages;
    BEGIN
      SELECT (r.content::jsonb) INTO v_body FROM extensions.http(('GET',
        'https://api.tiny.com.br/public-api/v3/notas?dataInicial='||p_de||'&dataFinal='||p_ate||'&limit=100&offset='||v_off,
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL)::extensions.http_request) r;
    EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    v_total := (v_body->'paginacao'->>'total')::int;
    v_cnt := jsonb_array_length(coalesce(v_body->'itens','[]'::jsonb));
    EXIT WHEN v_cnt = 0;
    FOR v_id IN
      SELECT (it->>'id')::bigint FROM jsonb_array_elements(v_body->'itens') it
      WHERE it->>'tipo' = 'S' AND coalesce(it->'ecommerce'->>'nome','') = ''
    LOOP
      PERFORM pg_sleep(0.08);
      SELECT (r.content::jsonb) INTO v_det FROM extensions.http(('GET',
        'https://api.tiny.com.br/public-api/v3/notas/'||v_id,
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL)::extensions.http_request) r;
      v_nat := v_det->'itens'->0->>'naturezaOperacao';
      CONTINUE WHEN coalesce(v_nat,'') NOT ILIKE 'Venda%';
      INSERT INTO public.b2b_notas (id, numero, serie, data_emissao, valor_produtos, valor_total, situacao, cliente_nome, cliente_cnpj, natureza)
      VALUES ((v_det->>'id')::bigint, v_det->>'numero', v_det->>'serie', (v_det->>'dataEmissao')::date,
        nullif(v_det->>'valorProdutos','')::numeric, nullif(v_det->>'valor','')::numeric, nullif(v_det->>'situacao','')::int,
        v_det->'cliente'->>'nome', v_det->'cliente'->>'cpfCnpj', v_nat)
      ON CONFLICT (id) DO UPDATE SET numero=excluded.numero, serie=excluded.serie, data_emissao=excluded.data_emissao,
        valor_produtos=excluded.valor_produtos, valor_total=excluded.valor_total, situacao=excluded.situacao,
        cliente_nome=excluded.cliente_nome, cliente_cnpj=excluded.cliente_cnpj, natureza=excluded.natureza;
      DELETE FROM public.b2b_itens WHERE nota_id = v_id;
      INSERT INTO public.b2b_itens (id, nota_id, sku, descricao, quantidade, valor_unitario, valor_total, cfop, natureza)
      SELECT (it->>'idItem')::bigint, v_id, it->>'codigo', it->>'descricao', nullif(it->>'quantidade','')::numeric,
             nullif(it->>'valorUnitario','')::numeric, nullif(it->>'valorTotal','')::numeric, it->>'cfop', it->>'naturezaOperacao'
      FROM jsonb_array_elements(v_det->'itens') it;
      v_n := v_n + 1;
    END LOOP;
    v_scanned := v_scanned + v_cnt;
    v_off := v_off + 100;
    IF v_off >= v_total THEN v_fim := true; EXIT; END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
  RETURN jsonb_build_object('proximo_offset', v_off, 'total_mes', v_total, 'terminou', v_fim,
    'scaneadas_lote', v_scanned, 'b2b_gravadas_lote', v_n);
END $function$;
