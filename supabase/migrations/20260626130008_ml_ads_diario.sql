-- Gasto diário de publicidade (Mercado Ads), por PRODUTO (não por campanha).
-- Régua: atribuição pela DATA do gasto (igual Full). Fontes (API de Ads, advertiser 20126):
--   product_ads (PADS)  -> campo cost           (product_ads/campaigns/search, DAILY)
--   brand_ads  (BADS)   -> campo consumed_budget (brand_ads/campaigns/metrics, daily)
-- 'seguidores' (CDLIT, só billing) fica de fora por ora — entra como outra linha depois.
create table if not exists public.ml_ads_diario (
  data          date    not null,
  produto       text    not null,   -- 'product_ads' | 'brand_ads' | (futuro: 'seguidores' | 'display')
  gasto         numeric(14,2),
  atualizado_em timestamptz not null default now(),
  primary key (data, produto)
);
alter table public.ml_ads_diario enable row level security;
