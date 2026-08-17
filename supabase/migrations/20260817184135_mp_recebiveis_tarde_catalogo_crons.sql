-- ============================================================================
-- Registra o job mp-recebiveis-tarde no catálogo do /crons  ·  17/08/2026
-- ============================================================================
-- Mesma técnica idempotente da 20260817183245: patch da definição viva de
-- crons_status(), inserindo a linha antes da âncora 'ml-semanal'.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('mp-recebiveis-tarde' in v_def) > 0 then
    raise notice 'catálogo já tem mp-recebiveis-tarde';
    return;
  end if;

  v_row := $r$('mp-recebiveis-tarde','Mercado Pago','diario','Todo dia às 13:00 BRT',
     'Segunda passada dos recebíveis do dia: pega as vendas da manhã e o dinheiro que já foi liberado, pra o F.C. Projetado não ficar com a foto da madrugada durante a tarde.',
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
