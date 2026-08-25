-- Omie contas a pagar: 2ª sincronização diária, à tarde (16:20 BRT).
--
-- Motivo (incidente de 25/08/2026): o AP só sincronizava 1×/dia (omie-diario,
-- 05:00 BRT) e o F.C. Projetado ficava até 24h defasado do que o financeiro
-- faz na Omie durante o dia. Dois efeitos medidos no mesmo dia:
--   (a) NF Firenze 000002272/1 (R$ 70,9k) reprogramada de 04/09 → 05/09
--       durante o dia — a página mostrava o dia errado ("no dia 5/9 vc nao
--       puxou uma nf da firenze", Luciano);
--   (b) boletos do próprio dia pagos à tarde continuavam contando como saída
--       E já tinham saído do saldo em conta das 16:30 (dupla contagem
--       intradiária): D+0 caiu de R$ 542k → R$ 188,8k após o refresh.
--
-- Horário: 16:20 BRT (19:20 UTC), 10 min ANTES do omie-saldos das 16:30 —
-- a foto vespertina (AP + saldo) sai coerente. A função omie_fill_despesas()
-- é o mesmo re-sync completo do diário (~5k títulos, 51 páginas, ~1 min),
-- idempotente, com soft-delete de órfãos.

select cron.schedule('omie-ap-tarde', '20 19 * * *',
  $$SET statement_timeout='400s'; SELECT public.omie_fill_despesas();$$);

-- Catálogo da página /crons.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';
  if position('omie-ap-tarde' in v_def) > 0 then
    raise notice 'catálogo já tem omie-ap-tarde'; return;
  end if;
  v_row := $r$('omie-ap-tarde','Omie','diario','Todo dia às 16:20 BRT',
     'Segunda passada do dia nas contas a pagar da Omie (a primeira é às 05:00): captura pagamentos feitos e datas reprogramadas pelo financeiro durante o dia, para o F.C. Projetado da tarde não ficar defasado. Roda 10 min antes da coleta de saldo das 16:30.',
     'honesto', 28, null),
    $r$;
  v_new := replace(v_def, '(''ml-semanal'',''Mercado Livre'',''semanal''', v_row || '(''ml-semanal'',''Mercado Livre'',''semanal''');
  if v_new = v_def then raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado'; end if;
  execute v_new;
end
$do$;
