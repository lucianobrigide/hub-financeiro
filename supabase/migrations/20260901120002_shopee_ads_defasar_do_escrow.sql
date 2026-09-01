-- shopee-ads-reconferir-* e shopee-escrow-* disparavam no MESMO minuto (0 15 e
-- 0 21 UTC) e disputavam o advisory lock do refresh de token da Shopee: em
-- 31/08/2026 18:00 BRT o ads-reconferir morreu em statement_timeout esperando o
-- lock (segurado pelo escrow) e o ADS de 31/08 ficou sem dado até re-coleta manual
-- (R$ 1.643,62). Fix: defasar os jobs de ADS em 20 minutos (12:20 e 18:20 BRT) —
-- o escrow roda primeiro e o refresh de token já está feito quando o ADS começa.

select cron.schedule('shopee-ads-reconferir-meiodia', '20 15 * * *',
  $cmd$select public.shopee_ads_reconferir()$cmd$);

select cron.schedule('shopee-ads-reconferir-tarde', '20 21 * * *',
  $cmd$select public.shopee_ads_reconferir()$cmd$);
