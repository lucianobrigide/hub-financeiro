-- Keepalive do token TINY: roda a cada 4h pra manter a cadeia de refresh viva.
-- Access token ~4h, refresh token 24h (rotaciona). Com margem de 10 min,
-- o cron renova ~10 min antes de expirar. Se falhar 1 rodada, sobram 4h de
-- folga no access e >20h no refresh — auto-cicatrizante.
-- O refresh primário é on-demand (Edge tiny-token chama tiny_refresh_token).
select cron.schedule(
  'tiny-token-keepalive',
  '25 */4 * * *',
  $$select public.tiny_refresh_token(false)$$
);
