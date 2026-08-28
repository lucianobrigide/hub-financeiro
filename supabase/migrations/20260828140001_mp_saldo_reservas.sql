-- ═══════════════════════════════════════════════════════════════════════════
-- mp_saldo_colher v2 — reservas do MP deixam de inflar os fluxos (28/08/2026)
--
-- Achado do Luciano ("ontem não saiu 800k do caixa"): as saídas de 27/08
-- mostravam R$ 800.101,38, mas R$ 523.777,26 eram `reserve_for_payment` —
-- reserva E liberação NO MESMO DIA em volta do pagamento da fatura do ML
-- ("Faturas com tarifas por operar", R$ 261.888,63 via available_money) — e o
-- parser somava os DOIS lados (inflava créditos e débitos em 523k, líquido 0).
-- Saída real do MP em 27/08: fatura ML 261.888,63 + mediações ~6k.
--
-- Fix: TODA linha `reserve_for_%` (payment, payout, dispute, bpp_shipping...)
-- vira saldo-only e acumula o LÍQUIDO em `reserva_liquida` (débito − crédito;
-- positivo = dinheiro travado no dia). O líquido entra nos fluxos do dia
-- (débito se prende, crédito se solta) para a identidade continuar EXATA:
-- fech = abertura + creditos − debitos − payouts. O gross das reservas some
-- dos fluxos — só o efeito real no disponível conta.
-- Backfill: re-parse das janelas existentes 01→27/08 (mesmos arquivos).
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.mp_saldo_dia add column if not exists reserva_liquida numeric(14,2) default 0;
comment on column public.mp_saldo_dia.reserva_liquida is
'Líquido das linhas reserve_for_% do dia (débitos − créditos; positivo = dinheiro travado). Já embutido em creditos/debitos para a identidade fechar — coluna informativa/monitoração.';

create or replace function public.mp_saldo_colher(p_de date, p_ate date)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $function$
declare
  v_tok text; v_lista jsonb; v_file text; v_csv text;
  v_l text; v_c text[]; v_desc text; v_dt date; v_rn int := 0;
  v_abertura numeric; v_fech_footer numeric;
  v_dia date; v_prev numeric; v_err text;
  v_tot int := 0;
begin
  select access_token into v_tok from public.ml_get_state();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000');

  v_lista := (extensions.http((
    'GET', 'https://api.mercadopago.com/v1/account/release_report/list',
    ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_tok)], null, null
  )::extensions.http_request)).content::jsonb;
  select e->>'file_name' into v_file
  from jsonb_array_elements(v_lista) e
  where (e->>'begin_date')::timestamptz = (to_char(p_de, 'YYYY-MM-DD') || 'T03:00:00Z')::timestamptz
    and (e->>'end_date')::timestamptz   = (to_char(p_ate + 1, 'YYYY-MM-DD') || 'T02:59:59Z')::timestamptz
  order by e->>'date_created' desc limit 1;
  if v_file is null then
    insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
    values (now(), 'mp_saldo', p_ate, false, format('colher %s..%s: relatório ainda não disponível', p_de, p_ate));
    return jsonb_build_object('ok', false, 'erro', 'relatorio_indisponivel');
  end if;

  v_csv := (extensions.http((
    'GET', 'https://api.mercadopago.com/v1/account/release_report/' || v_file,
    ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_tok)], null, null
  )::extensions.http_request)).content;

  create temp table _mp_dia (
    data date primary key, cred numeric default 0, deb numeric default 0,
    payout numeric default 0, res numeric default 0, saldo_fim numeric, linhas int default 0
  ) on commit drop;

  for v_l in select * from regexp_split_to_table(v_csv, E'\n') loop
    v_rn := v_rn + 1;
    if v_rn = 1 or v_l = '' then continue; end if;
    v_c := string_to_array(v_l, ';');
    if array_length(v_c, 1) < 22 then continue; end if;
    v_desc := coalesce(v_c[3], '');
    if v_c[1] = '' or v_c[1] is null then
      v_fech_footer := nullif(v_c[4], '')::numeric;
      continue;
    end if;
    v_dt := left(v_c[1], 10)::date;
    if v_desc = '' then
      if v_abertura is null then v_abertura := nullif(v_c[4], '')::numeric; end if;
      continue;
    end if;
    if v_desc like 'pre_payout%' or v_desc like 'post_payout%' then continue; end if;

    insert into _mp_dia (data) values (v_dt) on conflict (data) do nothing;
    if v_desc = 'payout' then
      update _mp_dia set payout = payout + coalesce(nullif(v_c[5], '')::numeric, 0),
                         saldo_fim = coalesce(nullif(v_c[22], '')::numeric, saldo_fim),
                         linhas = linhas + 1
      where data = v_dt;
    elsif v_desc like 'reserve_for_%' then
      -- reserva/liberação: não é fluxo — só o LÍQUIDO travado conta (v2, 28/08/2026)
      update _mp_dia set res = res + coalesce(nullif(v_c[5], '')::numeric, 0)
                                   - coalesce(nullif(v_c[4], '')::numeric, 0),
                         saldo_fim = coalesce(nullif(v_c[22], '')::numeric, saldo_fim),
                         linhas = linhas + 1
      where data = v_dt;
    else
      update _mp_dia set cred = cred + coalesce(nullif(v_c[4], '')::numeric, 0),
                         deb  = deb  + coalesce(nullif(v_c[5], '')::numeric, 0),
                         saldo_fim = coalesce(nullif(v_c[22], '')::numeric, saldo_fim),
                         linhas = linhas + 1
      where data = v_dt;
    end if;
  end loop;

  v_prev := v_abertura;
  for v_dia in select generate_series(p_de, p_ate, interval '1 day')::date loop
    insert into public.mp_saldo_dia as t
      (data, abertura, fechamento, creditos, debitos, payouts, reserva_liquida, linhas, file_name, coletado_em)
    select v_dia, v_prev,
           coalesce((select saldo_fim from _mp_dia where data = v_dia), v_prev),
           coalesce((select cred + greatest(-res, 0) from _mp_dia where data = v_dia), 0),
           coalesce((select deb + greatest(res, 0) from _mp_dia where data = v_dia), 0),
           coalesce((select payout from _mp_dia where data = v_dia), 0),
           coalesce((select res from _mp_dia where data = v_dia), 0),
           coalesce((select linhas from _mp_dia where data = v_dia), 0),
           v_file, now()
    on conflict (data) do update set
      abertura = excluded.abertura, fechamento = excluded.fechamento,
      creditos = excluded.creditos, debitos = excluded.debitos,
      payouts = excluded.payouts, reserva_liquida = excluded.reserva_liquida,
      linhas = excluded.linhas,
      file_name = excluded.file_name, coletado_em = excluded.coletado_em;
    v_prev := coalesce((select saldo_fim from _mp_dia where data = v_dia), v_prev);
    v_tot := v_tot + 1;
  end loop;
  if v_fech_footer is not null then
    update public.mp_saldo_dia set fechamento = v_fech_footer where data = p_ate;
  end if;

  drop table _mp_dia;
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'mp_saldo', p_ate, true,
          format('colhido %s..%s (%s dias) · fechamento %s = %s', p_de, p_ate, v_tot, p_ate,
                 (select fechamento from public.mp_saldo_dia where data = p_ate)));
  return jsonb_build_object('ok', true, 'dias', v_tot,
    'fechamento', (select fechamento from public.mp_saldo_dia where data = p_ate));
exception when others then
  v_err := sqlerrm;
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'mp_saldo', p_ate, false, 'ERRO: ' || left(v_err, 250));
  return jsonb_build_object('ok', false, 'erro', v_err);
end $function$;

comment on function public.mp_saldo_colher(date, date) is
'v2 (28/08/2026): parseia o release report do MP em mp_saldo_dia. payout = perna interna (coluna própria); linhas reserve_for_% = saldo-only, líquido em reserva_liquida (embutido nos fluxos p/ identidade exata) — antes o gross das reservas inflava créditos E débitos (27/08: R$523.777,26 de reserve_for_payment em volta do pagamento da fatura ML de R$261.888,63 fazia o dia mostrar 800k de saída). Identidade: fech = abertura + creditos − debitos − payouts.';
