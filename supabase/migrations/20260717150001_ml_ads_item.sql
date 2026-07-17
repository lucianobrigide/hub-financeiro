-- ADS por ITEM por dia (Product Ads do ML). Fonte:
--   GET /advertising/MLB/advertisers/{adv}/product_ads/ads/search?date_from=D&date_to=D&metrics=cost
--   (header api-version:2) — 1 chamada/dia retorna todos os itens anunciados com metrics.cost.
-- Soma por item ≈ total diário do product_ads (~0,1%). Cron diário: job pg_cron 'ml-ads-item'
-- (25 6 * * * UTC) rodando ml_fill_ads_item(mês corrente). Backfill jun/jul feito.
-- NOTA: definição completa aplicada via MCP (migration ml_ads_item_ingest). Este arquivo documenta.
CREATE TABLE IF NOT EXISTS public.ml_ads_item_diario (
  data date NOT NULL, item_id text NOT NULL, gasto numeric NOT NULL DEFAULT 0,
  atualizado_em timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (data, item_id)
);
ALTER TABLE public.ml_ads_item_diario ENABLE ROW LEVEL SECURITY;
-- função public.ml_fill_ads_item(p_month text): ver migration ml_ads_item_ingest no banco.
