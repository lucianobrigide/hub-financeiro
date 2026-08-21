-- Mercado Pago — 3ª passada diária dos recebíveis (19:00 BRT) · 20/08/2026
-- Decisão do Luciano na revisão plataforma a plataforma: com 2 fotos/dia
-- (04:15 e 13:00 BRT) o card envelhecia até ~R$ 20-60k durante a tarde/noite
-- (o MP libera dinheiro continuamente e as vendas novas não entravam).
-- Validação de 20/08: tela "A receber" R$ 999.683,53 ficou exatamente entre
-- os dois recortes do Hub — diferença 100% timing. Custo medido: ~100s/execução.
select cron.schedule('mp-recebiveis-noite', '0 22 * * *',
  $$select public.mp_fill_recebiveis(120, 300);$$);

-- Catálogo da página /crons (mesma técnica idempotente das outras migrations).
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';

  if position('mp-recebiveis-noite' in v_def) > 0 then
    raise notice 'catálogo já tem mp-recebiveis-noite';
    return;
  end if;

  v_row := $r$('mp-recebiveis-noite','Mercado Pago','diario','Todo dia às 19:00 BRT',
     'Terceira passada dos recebíveis do Mercado Pago no mesmo dia — o MP libera dinheiro continuamente e a foto das 13:00 envelhecia dezenas de milhares de reais até a noite.',
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
