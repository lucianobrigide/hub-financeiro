-- Crons dos recebíveis Amazon · 17/08/2026 — mesma cadência do MP e da Shopee
-- (madrugada + 13:00), pra os cards do F.C. Projetado envelhecerem juntos.
-- Ingestão leve: 1 chamada à Edge, ~37 grupos.
select cron.schedule('az-recebiveis',       '40 7 * * *',  $$select public.az_fill_recebiveis(180);$$);
select cron.schedule('az-recebiveis-tarde', '20 16 * * *', $$select public.az_fill_recebiveis(180);$$);

-- Catálogo da página /crons (técnica idempotente das demais migrations).
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('az-recebiveis' in v_def) > 0 then
    raise notice 'catálogo já tem az-recebiveis';
    return;
  end if;

  v_row := $r$('az-recebiveis','Amazon','diario','Todo dia às 04:40 BRT',
     'Puxa da Amazon os ciclos financeiros (grupos de ~14 dias): quanto já está a caminho do banco, com a data da transferência, e quanto o ciclo corrente acumulou. Alimenta os Recebíveis do F.C. Projetado. Roda de novo às 13:20.',
     'honesto', 28, null),
    ('az-recebiveis-tarde','Amazon','diario','Todo dia às 13:20 BRT',
     'Segunda passada dos ciclos financeiros da Amazon no mesmo dia.',
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
