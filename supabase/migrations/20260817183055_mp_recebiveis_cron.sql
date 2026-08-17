-- ============================================================================
-- Mercado Pago — cron diário dos recebíveis  ·  17/08/2026
-- ============================================================================
-- 07:15 UTC = 04:15 BRT: roda DEPOIS do ml-diario (03:00 BRT) e do
-- ml-refresh-token, que mantêm vivo o access_token usado por esta ingestão
-- (o MP não tem credencial própria — ver 20260817182655_mp_recebiveis.sql).
-- ~91 páginas / 9k pagamentos / ~1-2 min por execução.

select cron.schedule('mp-recebiveis', '15 7 * * *', $$select public.mp_fill_recebiveis(120, 300);$$);
