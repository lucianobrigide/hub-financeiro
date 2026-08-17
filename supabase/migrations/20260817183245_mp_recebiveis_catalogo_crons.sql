-- ============================================================================
-- Mercado Pago — registra o job mp-recebiveis no catálogo do /crons · 17/08/2026
-- ============================================================================
-- crons_status() carrega o catálogo hardcoded num VALUES. Em vez de reescrever
-- as ~9,8k de definição (e arriscar perder uma linha), insere-se a linha nova
-- ANTES da âncora 'ml-semanal' na própria definição viva da função.
-- Idempotente: se 'mp-recebiveis' já estiver no catálogo, não faz nada.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('mp-recebiveis' in v_def) > 0 then
    raise notice 'catálogo já tem mp-recebiveis';
    return;
  end if;

  v_row := $r$('mp-recebiveis','Mercado Pago','diario','Todo dia às 04:15 BRT',
     'Puxa do Mercado Pago todos os pagamentos que ainda vão ser liberados (próximos 120 dias), com o valor líquido real de cada um. É o que alimenta os Recebíveis por plataforma do F.C. Projetado.',
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
