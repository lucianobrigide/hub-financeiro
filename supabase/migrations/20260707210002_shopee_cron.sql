-- Keepalive do token Shopee: roda a cada 3h pra manter a cadeia de refresh viva.
-- Access token 4h, refresh token 30 dias (rotaciona). Com margem de 30 min,
-- o cron renova ~30 min antes de expirar. Se falhar 1 rodada, sobram ~3h de
-- folga no access — auto-cicatrizante.
-- O refresh primário é on-demand (Edge shopee-token chama shopee_refresh_token).
select cron.schedule(
  'shopee-token-keepalive',
  '15 */3 * * *',
  $$select public.shopee_refresh_token(false)$$
);
