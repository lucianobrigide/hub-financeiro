-- ============================================================
-- Amazon: tabela de pedidos + RPCs de upsert/faturamento + orquestrador
-- ============================================================

-- 1. Tabela de pedidos Amazon (competência por PurchaseDate)
CREATE TABLE public.az_pedidos (
  amazon_order_id TEXT PRIMARY KEY,
  purchase_date   DATE NOT NULL,
  status          TEXT NOT NULL,
  total           NUMERIC(12,2),
  currency        TEXT DEFAULT 'BRL',
  num_items       INTEGER DEFAULT 0,
  atualizado_em   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.az_pedidos ENABLE ROW LEVEL SECURITY;

-- 2. Upsert em lote (recebe JSONB array)
CREATE OR REPLACE FUNCTION public.az_upsert_pedidos(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_count integer := 0;
BEGIN
  INSERT INTO public.az_pedidos (amazon_order_id, purchase_date, status, total, currency, num_items, atualizado_em)
  SELECT
    r->>'amazon_order_id',
    (r->>'purchase_date')::date,
    r->>'status',
    (r->>'total')::numeric,
    COALESCE(r->>'currency', 'BRL'),
    COALESCE((r->>'num_items')::integer, 0),
    now()
  FROM jsonb_array_elements(p_rows) AS r
  ON CONFLICT (amazon_order_id) DO UPDATE SET
    purchase_date = EXCLUDED.purchase_date,
    status        = EXCLUDED.status,
    total         = EXCLUDED.total,
    currency      = EXCLUDED.currency,
    num_items     = EXCLUDED.num_items,
    atualizado_em = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- 3. Faturamento bruto Amazon (régua: NOT IN Canceled/Pending/Unfulfillable)
CREATE OR REPLACE FUNCTION public.az_faturamento(p_month text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'faturamento_bruto', COALESCE(SUM(total), 0),
    'total_pedidos', COUNT(*)
  )
  FROM public.az_pedidos
  WHERE to_char(purchase_date, 'YYYY-MM') = p_month
    AND status NOT IN ('Canceled', 'Pending', 'Unfulfillable');
$$;

-- 4. az_edge_call — chama Edge Function az-ingest-dia (clone de ml_edge_call)
CREATE OR REPLACE FUNCTION public.az_edge_call(p_body jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_url text := 'https://klwczmapuupensozxbsr.supabase.co/functions/v1/az-ingest-dia';
  v_key text; v_status int; v_raw text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'az_token_key';
  IF v_key IS NULL OR v_key = '' THEN
    RETURN jsonb_build_object('http_status', 0, 'body', jsonb_build_object('error','missing_key'));
  END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '150000');
  SELECT r.status, r.content INTO v_status, v_raw
  FROM extensions.http((
    'POST', v_url, array[ extensions.http_header('x-api-key', v_key) ],
    'application/json', p_body::text
  )::extensions.http_request) AS r;
  RETURN jsonb_build_object('http_status', v_status,
    'body', CASE WHEN left(coalesce(v_raw,''),1) = '{' THEN v_raw::jsonb ELSE to_jsonb(coalesce(v_raw,'')) END);
END;
$$;

-- 5. Orquestrador diário Amazon (fecha ontem + loga)
CREATE OR REPLACE FUNCTION public.az_cron_diario()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_t timestamptz;
BEGIN
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
  RETURN jsonb_build_object('ontem', v_ontem, 'pedidos', COALESCE((v_res->'body'->>'pedidos')::int, 0));
END;
$$;

-- 6. Cron diário Amazon: 03:15 BRT (15 min após ML diário)
SELECT cron.schedule(
  'az-diario',
  '15 6 * * *',
  $$SET statement_timeout = '45min'; SELECT public.az_cron_diario();$$
);
