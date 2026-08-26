-- F.C. Projetado: SALDO DISPONÍVEL do Mercado Pago no caixa consolidado
-- (pedido do Luciano 26/08/2026: "temos dinheiro LIBERADO no Mercado Pago que
--  ainda não foi transferido para o Itaú — esse valor precisa estar no saldo.
--  Você lê o que libera; precisa ler também o que JÁ está liberado").
--
-- Fonte REAL encontrada (26/08): o endpoint direto de saldo segue bloqueado
-- (403/404 com o token ML), mas o RELATÓRIO DE LIBERAÇÕES aceita nosso token:
--   POST /v1/account/release_report {begin_date, end_date}  (assíncrono ~5min)
--   GET  /v1/account/release_report/list                     (fila)
--   GET  /v1/account/release_report/{file_name}              (CSV ';')
-- O CSV traz BALANCE_AMOUNT = SALDO DISPONÍVEL CORRENTE linha a linha:
--   · 1ª linha (DESCRIPTION vazio) = saldo inicial disponível da janela;
--   · última linha (sem data)      = rodapé com o saldo FINAL na col. crédito;
--   · linhas pre_payout_*/post_payout_* são MARCADORES (saldo antes/depois da
--     transferência), não movimento — excluídas;
--   · 'payout' (débito) = transferência para conta bancária = perna interna
--     (o crédito correspondente aparece no extrato do banco como
--     "Transf. Mercado Pago >> ..."); 'reserve_for_payout' é o par
--     reserva/liberação da mesma transferência — ambos excluídos dos fluxos.
-- Validação (25/08/2026): abertura 579.846,05 + créditos reais 322.760,52 −
-- débitos reais 417.735,94 = 484.870,63 = rodapé, centavo a centavo; e o
-- payout de 200.000,00 casa com o crédito do Itaú no mesmo dia.
--
-- Modelo do caixa consolidado (fc_historico v5):
--   caixa(D) = bancos_fim(D) + mp_disponivel_fim(D)
--   entradas(D) = banco (excl. transf. vindas do MP, agora internas) + MP
--     (liberações/estornos/etc., excl. payout e marcadores)
--   saídas(D)   = banco + MP (mediações etc., excl. payout)
--   identidade: fech(D) = fech(D−1) + ent − sai (pernas internas se anulam
--   no mesmo dia — payout é Pix instantâneo).
-- Dia sem relatório do MP: carrega o fechamento anterior com fluxo 0 (o
-- colher re-varre 3 dias e se auto-corrige). Liberações de HOJE continuam
-- como entradas PROJETADAS (cronograma), viram reais no relatório de amanhã.

create table if not exists public.mp_saldo_dia (
  data        date primary key,
  abertura    numeric(14,2),           -- saldo disponível no início do dia
  fechamento  numeric(14,2),           -- saldo disponível no fim do dia
  creditos    numeric(14,2) not null,  -- fluxo real de entrada no disponível (excl. payout/marcadores)
  debitos     numeric(14,2) not null,  -- fluxo real de saída (excl. payout/marcadores)
  payouts     numeric(14,2) not null,  -- transferências para conta bancária (informativo/validação)
  linhas      int not null,
  file_name   text,
  coletado_em timestamptz not null default now()
);
comment on table public.mp_saldo_dia is
'Saldo DISPONÍVEL diário do Mercado Pago (release report): abertura/fechamento e fluxos reais do disponível (payout = transferência p/ banco, tratada como interna no caixa consolidado). Coleta: mp_saldo_pedir + mp_saldo_colher (crons mp-saldo-*).';

-- Pede um relatório de liberações para a janela [p_de, p_ate] (dias BRT).
create or replace function public.mp_saldo_pedir(p_de date, p_ate date)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_tok text; v_resp extensions.http_response;
begin
  select access_token into v_tok from public.ml_get_state();
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');
  v_resp := extensions.http((
    'POST', 'https://api.mercadopago.com/v1/account/release_report',
    ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_tok)],
    'application/json',
    jsonb_build_object(
      'begin_date', to_char(p_de, 'YYYY-MM-DD') || 'T03:00:00Z',
      'end_date',   to_char(p_ate + 1, 'YYYY-MM-DD') || 'T02:59:59Z'
    )::text)::extensions.http_request);
  insert into public.ml_cron_log (executado_em, job, dia_alvo, sucesso, mensagem)
  values (now(), 'mp_saldo', p_ate, v_resp.status in (200, 202),
          format('pedido %s..%s -> HTTP %s', p_de, p_ate, v_resp.status));
  return jsonb_build_object('status', v_resp.status, 'body', left(v_resp.content, 200));
end $function$;

-- Colhe o relatório mais novo cuja janela bate com [p_de, p_ate] e grava
-- mp_saldo_dia (um registro por dia da janela; dia sem movimento carrega o
-- fechamento anterior).
create or replace function public.mp_saldo_colher(p_de date, p_ate date)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
set statement_timeout to '120s'
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

  -- relatório mais novo com a janela pedida
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
    payout numeric default 0, saldo_fim numeric, linhas int default 0
  ) on commit drop;

  for v_l in select * from regexp_split_to_table(v_csv, E'\n') loop
    v_rn := v_rn + 1;
    if v_rn = 1 or v_l = '' then continue; end if;   -- header / vazio
    v_c := string_to_array(v_l, ';');
    if array_length(v_c, 1) < 22 then continue; end if;
    v_desc := coalesce(v_c[3], '');
    if v_c[1] = '' or v_c[1] is null then
      -- rodapé: saldo final na coluna de crédito
      v_fech_footer := nullif(v_c[4], '')::numeric;
      continue;
    end if;
    v_dt := left(v_c[1], 10)::date;
    if v_desc = '' then
      -- linha inicial (saldo disponível no começo da janela)
      if v_abertura is null then v_abertura := nullif(v_c[4], '')::numeric; end if;
      continue;
    end if;
    if v_desc like 'pre_payout%' or v_desc like 'post_payout%' then continue; end if;  -- marcadores

    insert into _mp_dia (data) values (v_dt) on conflict (data) do nothing;
    if v_desc = 'payout' then
      update _mp_dia set payout = payout + coalesce(nullif(v_c[5], '')::numeric, 0),
                         saldo_fim = coalesce(nullif(v_c[22], '')::numeric, saldo_fim),
                         linhas = linhas + 1
      where data = v_dt;
    elsif v_desc = 'reserve_for_payout' then
      update _mp_dia set saldo_fim = coalesce(nullif(v_c[22], '')::numeric, saldo_fim),
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

  -- um registro por dia da janela; dia quieto carrega o fechamento anterior
  v_prev := v_abertura;
  for v_dia in select generate_series(p_de, p_ate, interval '1 day')::date loop
    insert into public.mp_saldo_dia as t
      (data, abertura, fechamento, creditos, debitos, payouts, linhas, file_name, coletado_em)
    select v_dia, v_prev,
           coalesce((select saldo_fim from _mp_dia where data = v_dia), v_prev),
           coalesce((select cred from _mp_dia where data = v_dia), 0),
           coalesce((select deb from _mp_dia where data = v_dia), 0),
           coalesce((select payout from _mp_dia where data = v_dia), 0),
           coalesce((select linhas from _mp_dia where data = v_dia), 0),
           v_file, now()
    on conflict (data) do update set
      abertura = excluded.abertura, fechamento = excluded.fechamento,
      creditos = excluded.creditos, debitos = excluded.debitos,
      payouts = excluded.payouts, linhas = excluded.linhas,
      file_name = excluded.file_name, coletado_em = excluded.coletado_em;
    v_prev := coalesce((select saldo_fim from _mp_dia where data = v_dia), v_prev);
    v_tot := v_tot + 1;
  end loop;
  -- o rodapé é o fechamento oficial do fim da janela — prevalece
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

revoke all on function public.mp_saldo_pedir(date, date) from public, anon, authenticated;
revoke all on function public.mp_saldo_colher(date, date) from public, anon, authenticated;

-- Saldo disponível mais recente (para o card do Mercado Pago nos recebíveis).
create or replace function public.mp_saldo_atual()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select jsonb_build_object('data', data, 'fechamento', fechamento, 'coletado_em', coletado_em)
                   from public.mp_saldo_dia
                   where fechamento is not null
                   order by data desc limit 1), '{}'::jsonb);
$function$;
revoke all on function public.mp_saldo_atual() from public, anon;
grant execute on function public.mp_saldo_atual() to service_role, authenticated;

-- Crons diários: pede o relatório de ONTEM (re-varrendo 3 dias, auto-correção)
-- às 07:45 BRT e colhe às 08:10 BRT — antes do omie-saldos (08:30) e do
-- fc-snapshot (08:45).
select cron.schedule('mp-saldo-pedir', '45 10 * * *',
  $$SELECT public.mp_saldo_pedir(((now() at time zone 'America/Sao_Paulo')::date - 3), ((now() at time zone 'America/Sao_Paulo')::date - 1));$$);
select cron.schedule('mp-saldo-colher', '10 11 * * *',
  $$SELECT public.mp_saldo_colher(((now() at time zone 'America/Sao_Paulo')::date - 3), ((now() at time zone 'America/Sao_Paulo')::date - 1));$$);

-- Catálogo da página /crons.
do $do$
declare v_def text; v_new text; v_row text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname='public' and p.proname='crons_status';
  if position('mp-saldo-pedir' in v_def) > 0 then
    raise notice 'catálogo já tem mp-saldo'; return;
  end if;
  v_row := $r$('mp-saldo-pedir','Mercado Pago','diario','Todo dia às 07:45 BRT',
     'Pede ao Mercado Pago o relatório de liberações dos últimos 3 dias — é dele que sai o saldo DISPONÍVEL (dinheiro já liberado e ainda não transferido ao banco) que compõe o caixa consolidado do F.C. Projetado.',
     'honesto', 28, null),
    ('mp-saldo-colher','Mercado Pago','diario','Todo dia às 08:10 BRT',
     'Baixa e processa o relatório de liberações pedido às 07:45: grava o saldo disponível e os fluxos reais do dia no Mercado Pago (mp_saldo_dia), fechando o caixa consolidado bancos + MP.',
     'honesto', 28, null),
    $r$;
  v_new := replace(v_def, '(''ml-semanal'',''Mercado Livre'',''semanal''', v_row || '(''ml-semanal'',''Mercado Livre'',''semanal''');
  if v_new = v_def then raise exception 'âncora ml-semanal não encontrada — catálogo NÃO alterado'; end if;
  execute v_new;
end
$do$;
