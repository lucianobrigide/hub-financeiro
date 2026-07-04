-- ============================================================
-- Amazon: fix upsert comissão + pendentes RPC + orquestrador atualizado
-- ============================================================

-- 1. Fix upsert: não reseta confirmado (OR preserva true)
CREATE OR REPLACE FUNCTION public.az_upsert_comissao(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_count integer := 0;
BEGIN
  INSERT INTO public.az_comissao (amazon_order_id, comissao_estimada, comissao_real, confirmado, fonte, atualizado_em)
  SELECT
    r->>'amazon_order_id',
    (r->>'comissao_estimada')::numeric,
    CASE WHEN r->>'comissao_real' IS NOT NULL THEN (r->>'comissao_real')::numeric END,
    COALESCE((r->>'confirmado')::boolean, false),
    COALESCE(r->>'fonte', 'estimate'),
    now()
  FROM jsonb_array_elements(p_rows) AS r
  ON CONFLICT (amazon_order_id) DO UPDATE SET
    comissao_estimada = EXCLUDED.comissao_estimada,
    comissao_real     = COALESCE(EXCLUDED.comissao_real, az_comissao.comissao_real),
    confirmado        = az_comissao.confirmado OR EXCLUDED.confirmado,
    fonte             = CASE WHEN EXCLUDED.comissao_real IS NOT NULL THEN EXCLUDED.fonte ELSE az_comissao.fonte END,
    atualizado_em     = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- 2. Pendentes: pedidos com comissão não confirmada
CREATE OR REPLACE FUNCTION public.az_pendentes_comissao()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'amazon_order_id', c.amazon_order_id,
    'comissao_estimada', c.comissao_estimada
  )), '[]'::jsonb)
  FROM public.az_comissao c
  WHERE NOT c.confirmado;
$$;

-- 3. Orquestrador atualizado: fechar + confirmar comissões pendentes
CREATE OR REPLACE FUNCTION public.az_cron_diario()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_res2 jsonb; v_t timestamptz;
BEGIN
  -- Passo 1: ingerir pedidos de ontem + estimar comissão
  v_t := clock_timestamp();
  v_res := az_edge_call(jsonb_build_object('modo','fechar','dia', v_ontem::text));
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  VALUES (
    'az-diario', v_ontem,
    (v_res->>'http_status') = '200',
    (v_res->>'http_status')::int,
    COALESCE((v_res->'body'->>'pedidos')::int, 0),
    COALESCE((v_res->'body'->>'valor')::numeric, 0),
    (extract(epoch from clock_timestamp() - v_t) * 1000)::int,
    'ok', v_res
  );

  -- Passo 2: confirmar comissões pendentes via Finances API
  v_t := clock_timestamp();
  v_res2 := az_edge_call(jsonb_build_object('modo','confirmar'));
  INSERT INTO public.ml_cron_log(job, dia_alvo, sucesso, http_status, pedidos, valor, duracao_ms, mensagem, resposta)
  VALUES (
    'az-confirmar', v_ontem,
    (v_res2->>'http_status') = '200',
    (v_res2->>'http_status')::int,
    COALESCE((v_res2->'body'->>'confirmados')::int, 0),
    0,
    (extract(epoch from clock_timestamp() - v_t) * 1000)::int,
    'ok', v_res2
  );

  RETURN jsonb_build_object(
    'ontem', v_ontem,
    'pedidos', COALESCE((v_res->'body'->>'pedidos')::int, 0),
    'confirmados', COALESCE((v_res2->'body'->>'confirmados')::int, 0)
  );
END;
$$;
