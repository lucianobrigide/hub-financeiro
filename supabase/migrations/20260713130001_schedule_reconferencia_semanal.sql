-- Agenda as reconferências semanais de Shopee/Amazon/TikTok (funções em 20260711120001).
-- Domingo de manhã (UTC), escalonadas depois do ml-semanal (08:00 UTC), sem colidir com
-- os diários (que terminam ~07:30 UTC). statement_timeout 45min (teto; as funções são
-- limitadas). Validadas via one-shot pg_cron em 2026-07-13.
select cron.schedule('shopee-semanal', '15 8 * * 0', $$SET statement_timeout='45min'; SELECT public.shopee_cron_semanal()$$);
select cron.schedule('az-semanal',     '30 8 * * 0', $$SET statement_timeout='45min'; SELECT public.az_cron_semanal()$$);
select cron.schedule('tt-semanal',     '45 8 * * 0', $$SET statement_timeout='45min'; SELECT public.tt_cron_semanal()$$);
