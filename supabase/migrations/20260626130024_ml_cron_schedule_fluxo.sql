-- Agenda o fluxo completo de ingestão e desativa o job antigo (o diário já inclui o fechar).
-- ml-diario  06:00 UTC (03:00 BRT): fechar(ontem) → frete(chunks) → ADS(ontem) → Full → reconferir 7d
-- ml-semanal 08:00 UTC domingo (05:00 BRT): reconferir 30 dias
select cron.unschedule('ml-fechar-ontem');
select cron.schedule('ml-diario',  '0 6 * * *', $$select public.ml_cron_diario();$$);
select cron.schedule('ml-semanal', '0 8 * * 0', $$select public.ml_cron_semanal();$$);
