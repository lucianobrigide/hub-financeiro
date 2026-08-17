-- ============================================================================
-- Mercado Pago — segunda passada dos recebíveis  ·  17/08/2026 (pedido do Luciano)
-- ============================================================================
-- 16:00 UTC = 13:00 BRT. A da madrugada (mp-recebiveis, 04:15) dá a foto do dia;
-- esta pega as vendas da manhã e as liberações que já caíram, pra o card não
-- ficar com a foto da madrugada durante a tarde — que é quando se olha caixa.
-- Custo medido: 100s por execução (9.011 pagamentos / 91 páginas), sem sinal de
-- throttle no /v1/payments/search.

select cron.schedule('mp-recebiveis-tarde', '0 16 * * *', $$select public.mp_fill_recebiveis(120, 300);$$);
