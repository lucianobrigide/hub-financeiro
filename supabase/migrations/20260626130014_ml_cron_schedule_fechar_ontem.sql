-- Agenda o fechamento diário de ONTEM às 06:00 UTC (= 03:00 America/Sao_Paulo, UTC−3).
-- 03h da manhã: o dia anterior já está 100% fechado e o tráfego é mínimo.
-- Só o fechar(ontem); o reconferir (janela 30d, por-dia) é agendado noutro passo.
select cron.schedule('ml-fechar-ontem', '0 6 * * *', $$select public.ml_cron_fechar_ontem();$$);
