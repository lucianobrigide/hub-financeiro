-- Keepalive do token TikTok Shop: roda diariamente.
-- Access token ~7 dias, refresh ~99 anos (rotaciona). Margem de 2 dias no refresh.
-- Com cron diário, renova ~5 dias após criação — sobram 2 dias de folga.
select cron.schedule(
  'tt-token-keepalive',
  '0 7 * * *',
  $$select public.tt_refresh_token(false)$$
);
