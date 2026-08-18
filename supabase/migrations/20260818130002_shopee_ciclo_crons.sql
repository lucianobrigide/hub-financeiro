-- Crons do ciclo de vida Shopee (Fase 1 dos recebíveis com data) · 18/08/2026
-- Rodam DEPOIS das passadas da carteira (04:30 / 13:10 BRT): o universo do
-- ciclo é "pendente de recebível", que depende da carteira fresca.
-- statement_timeout explícito: a fase de tracking é 1 chamada/pedido e pode
-- passar de 2min em dia de muita entrega.
select cron.schedule('shopee-ciclo',       '0 8 * * *',
  $$set statement_timeout to '8min'; select public.shopee_fill_ciclo(30, 250);$$);
select cron.schedule('shopee-ciclo-tarde', '40 16 * * *',
  $$set statement_timeout to '8min'; select public.shopee_fill_ciclo(30, 250);$$);

-- Catálogo da página /crons (mesma técnica idempotente do shopee-wallet).
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('shopee-ciclo' in v_def) > 0 then
    raise notice 'catálogo já tem shopee-ciclo';
    return;
  end if;

  v_row := $r$('shopee-ciclo','Shopee','diario','Todo dia às 05:00 BRT',
     'Atualiza o ciclo de vida dos pedidos pendentes de recebível (status atual, data de entrega, prazos da Garantia): status fresco deixa o em_disputa preciso e a entrega é a âncora do futuro cronograma de recebíveis. Roda de novo às 13:40 (shopee-ciclo-tarde).',
     'honesto', 28, null),
    ('shopee-ciclo-tarde','Shopee','diario','Todo dia às 13:40 BRT',
     'Segunda passada do ciclo de vida Shopee no mesmo dia, depois da carteira da tarde — captura as entregas da manhã.',
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
