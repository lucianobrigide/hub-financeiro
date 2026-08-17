-- Crons da carteira Shopee (recebíveis do F.C. Projetado) · 17/08/2026
-- Mesma cadência do Mercado Pago (madrugada + 13:00), pra os dois cards do
-- F.C. Projetado envelhecerem juntos. Janela de 14 dias: cobre o ciclo inteiro
-- do escrow (98% do valor pendente está em pedidos de até 15 dias) e roda em
-- ~45s, contra 279s da carga de 90 dias.
select cron.schedule('shopee-wallet',       '30 7 * * *',  $$select public.shopee_fill_wallet(14);$$);
select cron.schedule('shopee-wallet-tarde', '10 16 * * *', $$select public.shopee_fill_wallet(14);$$);

-- Catálogo da página /crons (mesma técnica idempotente das migrations do MP).
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('shopee-wallet' in v_def) > 0 then
    raise notice 'catálogo já tem shopee-wallet';
    return;
  end if;

  v_row := $r$('shopee-wallet','Shopee','diario','Todo dia às 04:30 BRT',
     'Puxa as transações da carteira Shopee dos últimos 14 dias: é o que diz qual escrow JÁ caiu (e qual ainda está a receber) e qual é o saldo disponível. Roda de novo às 13:10 (shopee-wallet-tarde).',
     'honesto', 28, null),
    ('shopee-wallet-tarde','Shopee','diario','Todo dia às 13:10 BRT',
     'Segunda passada da carteira Shopee no mesmo dia, pra o F.C. Projetado não ficar com a foto da madrugada durante a tarde.',
     'honesto', 28, null),
    $r$;

  v_new := replace(
    v_def,
    '(''ml-semanal'',''Mercado Livre'',''semanal''',
    v_row || '(''ml-semanal'',''Mercado Livre'',''semanal'''
  );

  if v_new = v_def then
    raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado';
  end if;

  execute v_new;
end
$do$;
