-- Agenda o fluxo completo de ingestão e desativa o job antigo (o diário já inclui o fechar).
-- ml-diario  06:00 UTC (03:00 BRT): fechar(ontem) → frete(chunks) → ADS(ontem) → Full → reconferir 7d
-- ml-semanal 08:00 UTC domingo (05:00 BRT): reconferir 30 dias
-- NOTA: a sessão do worker do pg_cron cancela statements aos 2min (default da plataforma);
-- o fluxo leva ~10-15min → prefixamos SET statement_timeout (per-statement desde PG13).
select cron.unschedule('ml-fechar-ontem');
select cron.schedule('ml-diario',  '0 6 * * *', $$SET statement_timeout = '45min'; SELECT public.ml_cron_diario();$$);
select cron.schedule('ml-semanal', '0 8 * * 0', $$SET statement_timeout = '45min'; SELECT public.ml_cron_semanal();$$);
