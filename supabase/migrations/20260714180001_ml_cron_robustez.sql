-- ML — ROBUSTEZ COMPLETA DO CRON.
--
-- O QUE MOTIVOU: o trabalho de hoje criou uma ASSIMETRIA — o passo novo (diario_billing)
-- era auto-cicatrizante, mas os antigos (afiliados/difal/seguidores) batiam na MESMA API
-- instavel sem retry nem conferencia. Diagnostico ao vivo:
--   * diario_afiliados falhava HTTP 500 em 100% dos runs (10, 12, 13 e 14/07) e o CVAF
--     ficou CONGELADO em 10/07 — enquanto o log dizia 'ok' (mensagem hardcoded).
--     O endpoint respondia 200 quando chamado na mao => o 500 e TRANSITORIO e a Edge
--     abortava no 1o erro (`throw`), sem retry. 4 dias quebrado, ninguem avisado.
--
-- 1) BLINDAGEM (ml_edge_passo + ml_api_total)
--    afiliados/difal: retry + confere linhas na tabela vs `total` da API, refaz ate bater.
--    seguidores: SO retry — ele AGREGA por dia em ml_ads_diario (70 lidos -> 52 dias),
--    entao contagem de linhas NAO e comparavel. PENDENCIA registrada no Notion: fechar
--    gravando as linhas cruas em ml_billing_linhas e agregando na leitura.
--    ml_api_total tem retry PROPRIO: a verificacao tambem cai (visto ao vivo: a mesma key
--    devolveu 2499 e, minutos depois, NULL). Sem isso, daria falso "incompleto".
--
-- 2) OS 3 ESTADOS DA HONESTIDADE (ml_fill_billing) — a licao central do dia:
--      ok=false          -> o walk NEM RODOU (API fora)            = falha real, alerta
--      verificado=false  -> rodou mas nao deu pra ler o `total`    = NAO SEI, nao acusa
--      completo=t/f      -> verificado de verdade contra a API     = so alerta se false
--    FIX DE FALSO NEGATIVO: a 1a versao (commit c9dacb8) devolvia completo=false quando a
--    API nao respondia — logando "INCOMPLETO (API truncou)" com o dado INTEIRO no banco.
--    Trocar um 'ok' mentiroso por um "INCOMPLETO" mentiroso nao resolve: so inverte o erro
--    e faz o alerta gritar a toa (cry-wolf), treinando todo mundo a ignora-lo.
--    Confundir "nao sei" com "falhou" gera cry-wolf; com "funcionou" gera falso ok.
--
-- 3) LOG HONESTO — o log nao pode mentir. Eram 6x 'ok' e 2x sucesso=true HARDCODED.
--    Agora ZERO. O frete tinha um agravante: se a Edge falhava, v_restam virava false pelo
--    coalesce, o loop SAIA FINGINDO QUE TERMINOU e logava sucesso com gravados=0 — falha
--    invisivel. Agora sai com exit + erro real; estourar o guard de 25 chunks com pendentes
--    tambem conta como falha. reconferir7 idem (conta os dias que falharam).
--
-- 4) ALERTA (ml_saude): N=2 dias seguidos. 1 dia pode ser blip da API do ML (que rate-limita
--    sob carga: 429 "Bloqueio preventivo por quantidade limitada de requests por IP").
--    Expoe `tem_alerta` (bool, pra badge no dashboard) + `alerta_passos_falhando` (job,
--    dias_seguidos, ultimo_ok, erro). Some sozinho quando o passo volta a fechar — validado:
--    pegou o afiliados com 4 dias e zerou apos o destrave.
--
-- 5) ADVISORY LOCK 421982739 (serie dos crons: 737=tt, 738=shopee, 739=ml). O ML era o
--    UNICO cron sem lock. Descoberto na pratica: um run manual com o das 03:00 ainda ativo
--    rodava CONCORRENTE (2 backends), martelando a API que ja rate-limita. Os passos sao
--    idempotentes (nao corrompe dado), mas dobra a carga. Lock de SESSAO: o pg_cron roda
--    cada job num backend proprio, entao cai sozinho ao fim do job mesmo com excecao.
--    TESTADO com 2 sessoes reais (2 jobs pg_cron): a 2a sessao recebeu FALSE = bloqueada.
--    OBS: pg_try_advisory_lock e RE-ENTRANTE na mesma sessao — testar de uma conexao so
--    da falso positivo (o lock e readquirido e o cron roda). Tem que ser 2 sessoes.
--    PENDENCIA: ml_cron_semanal ainda NAO tem lock (no shopee/tt o diario e o semanal
--    COMPARTILHAM o mesmo lock). Risco baixo hoje (03:00 vs domingo 05:00, ~8min de run).
--
-- Definicoes capturadas via pg_get_functiondef (repo == banco).

-- ============ ml_api_total — le o `total` da API COM retry proprio ============
CREATE OR REPLACE FUNCTION public.ml_api_total(p_sub_type text, p_key text, p_tentativas integer DEFAULT 3)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_tok text; v_st int; v_body text; v_total int; i int;
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN RETURN NULL; END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','60000');
  FOR i IN 1..p_tentativas LOOP
    BEGIN
      SELECT r.status, r.content INTO v_st, v_body
      FROM extensions.http((
        'GET',
        'https://api.mercadolibre.com/billing/integration/periods/key/'||p_key||
        '/group/ML/details?document_type=BILL&detail_sub_types='||p_sub_type||
        '&limit=1&from_id=0&sort_by=ID&order_by=ASC',
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL
      )::extensions.http_request) r;
      IF v_st = 200 THEN
        v_total := (v_body::jsonb->>'total')::int;
        IF v_total IS NOT NULL THEN RETURN v_total; END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      NULL;  -- timeout/parse: cai no próximo retry
    END;
  END LOOP;
  RETURN NULL;
END $function$;

-- ============ ml_edge_passo — passo de billing blindado (retry + confere) ============
CREATE OR REPLACE FUNCTION public.ml_edge_passo(p_modo text, p_sub_type text DEFAULT NULL::text, p_tabela text DEFAULT NULL::text, p_tentativas integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_res jsonb; v_http int; v_erro text; i int;
  v_k0 text; v_k1 text; v_t0 int; v_t1 int; v_total_api int; v_no_banco int;
  v_completo boolean := NULL; v_hoje date;
BEGIN
  v_hoje := (now() at time zone 'America/Sao_Paulo')::date;
  v_k0 := to_char(v_hoje, 'YYYY-MM-01');
  v_k1 := to_char((v_hoje - interval '1 month')::date, 'YYYY-MM-01');

  FOR i IN 1..p_tentativas LOOP
    v_res  := ml_edge_call(jsonb_build_object('modo', p_modo));
    v_http := (v_res->>'http_status')::int;
    v_erro := v_res->'body'->>'detalhe';

    IF v_http = 200 THEN
      -- 200 não garante completo: a API trunca em silêncio. Confere quando dá.
      IF p_tabela IS NULL OR p_sub_type IS NULL THEN
        RETURN jsonb_build_object('completo', true, 'http_status', v_http,
          'tentativas', i, 'verificado', false, 'resposta', v_res);
      END IF;
      v_t0 := public.ml_api_total(p_sub_type, v_k0);
      v_t1 := public.ml_api_total(p_sub_type, v_k1);
      IF v_t0 IS NULL AND v_t1 IS NULL THEN
        -- não deu pra verificar (API fora): não mente dizendo completo.
        RETURN jsonb_build_object('completo', true, 'http_status', v_http,
          'tentativas', i, 'verificado', false,
          'aviso', 'API nao respondeu a verificacao de total', 'resposta', v_res);
      END IF;
      v_total_api := coalesce(v_t0,0) + coalesce(v_t1,0);
      EXECUTE format(
        'select count(*) from public.%I where periodo_key in ($1,$2)', p_tabela)
        INTO v_no_banco USING v_k0, v_k1;
      v_completo := v_no_banco >= v_total_api;
      IF v_completo THEN
        RETURN jsonb_build_object('completo', true, 'http_status', v_http, 'tentativas', i,
          'verificado', true, 'no_banco', v_no_banco, 'total_api', v_total_api);
      END IF;
      -- incompleto: re-tenta o walk (a Edge é idempotente por detail_id)
      v_erro := format('INCOMPLETO: %s de %s (API truncou)', v_no_banco, v_total_api);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('completo', coalesce(v_completo,false), 'http_status', v_http,
    'tentativas', p_tentativas, 'verificado', (v_completo IS NOT NULL),
    'no_banco', v_no_banco, 'total_api', v_total_api,
    'erro', coalesce(v_erro, 'HTTP '||coalesce(v_http::text,'?')));
END $function$;

-- ============ ml_fill_billing — 3 estados honestos (fix de falso negativo) ============
CREATE OR REPLACE FUNCTION public.ml_fill_billing(p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
 SET statement_timeout TO '300s'
AS $function$
DECLARE
  v_tok text; v_from bigint; v_page int; v_resp jsonb; v_res jsonb;
  v_last bigint; v_grav int; v_total_api int := NULL; v_no_banco int;
  v_try int := 0; v_paginas_ok int := 0; v_erro text := NULL;
  v_tipos text := 'BPAD,CXDED,CDSDB,CFPB,CXDID,BXDED,BDSDB,BXDID';
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'erro', 'sem_token', 'key', p_key);
  END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','60000');

  <<tentativas>>
  LOOP
    v_try := v_try + 1;
    v_from := 0; v_page := 0; v_grav := 0;

    LOOP
      v_page := v_page + 1;
      EXIT WHEN v_page > 60;
      BEGIN
        SELECT (r.content::jsonb) INTO v_resp
        FROM extensions.http((
          'GET',
          'https://api.mercadolibre.com/billing/integration/periods/key/'||p_key||
          '/group/ML/details?document_type=BILL&detail_sub_types='||v_tipos||
          '&limit=500&from_id='||v_from||'&sort_by=ID&order_by=ASC',
          ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL
        )::extensions.http_request) r;
      EXCEPTION WHEN OTHERS THEN
        v_resp := NULL; v_erro := 'http: '||SQLERRM;
      END;

      IF v_resp IS NULL THEN EXIT; END IF;
      IF v_total_api IS NULL THEN v_total_api := (v_resp->>'total')::int; END IF;
      v_res := v_resp->'results';
      EXIT WHEN v_res IS NULL OR jsonb_array_length(v_res) = 0;
      v_paginas_ok := v_paginas_ok + 1;

      INSERT INTO public.ml_billing_linhas
        (detail_id, creation_date, creation_date_time, detail_type, detail_sub_type,
         detail_amount, transaction_detail, order_id, periodo_key)
      SELECT (e->'charge_info'->>'detail_id')::bigint,
             (left(e->'charge_info'->>'creation_date_time',10))::date,
             (e->'charge_info'->>'creation_date_time')::timestamptz,
             e->'charge_info'->>'detail_type',
             e->'charge_info'->>'detail_sub_type',
             (e->'charge_info'->>'detail_amount')::numeric,
             e->'charge_info'->>'transaction_detail',
             nullif(e->'sales_info'->0->>'order_id','')::bigint,
             p_key
      FROM jsonb_array_elements(v_res) e
      ON CONFLICT (detail_id) DO UPDATE SET
        detail_amount = excluded.detail_amount,
        creation_date = excluded.creation_date,
        detail_sub_type = excluded.detail_sub_type,
        transaction_detail = excluded.transaction_detail,
        atualizado_em = now();

      v_grav := v_grav + jsonb_array_length(v_res);
      SELECT max((e->'charge_info'->>'detail_id')::bigint) INTO v_last
        FROM jsonb_array_elements(v_res) e;
      EXIT WHEN v_last IS NULL OR v_last = v_from;
      v_from := v_last;
    END LOOP;

    SELECT count(*) INTO v_no_banco FROM public.ml_billing_linhas WHERE periodo_key = p_key;
    EXIT tentativas WHEN v_total_api IS NULL
                      OR v_no_banco >= v_total_api
                      OR v_try >= 4;
  END LOOP;

  -- Estado 1: a API não respondeu NENHUMA página -> falha real (o walk nem rodou).
  IF v_paginas_ok = 0 AND v_total_api IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'verificado', false, 'key', p_key,
      'no_banco', v_no_banco, 'tentativas', v_try,
      'erro', coalesce(v_erro, 'API nao respondeu nenhuma pagina'));
  END IF;

  -- Estado 2: rodou, mas não deu pra ler o total -> NÃO SEI (não acusa incompleto).
  IF v_total_api IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'verificado', false, 'key', p_key,
      'no_banco', v_no_banco, 'tentativas', v_try,
      'aviso', 'API nao devolveu o total; completude NAO verificada');
  END IF;

  -- Estado 3: verificado de verdade.
  RETURN jsonb_build_object('ok', true, 'verificado', true, 'key', p_key,
    'completo', (v_no_banco >= v_total_api),
    'no_banco', v_no_banco, 'total_api', v_total_api, 'tentativas', v_try,
    'erro', case when v_no_banco < v_total_api
                 then format('INCOMPLETO: %s de %s', v_no_banco, v_total_api) end);
END $function$;

-- ============ ml_saude — alerta de passo falhando >= 2 dias seguidos ============
CREATE OR REPLACE FUNCTION public.ml_saude(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with ult as (
    -- último run de cada passo por dia (o cron roda 1x/dia; pega o mais recente do dia)
    select distinct on (job, (executado_em at time zone 'America/Sao_Paulo')::date)
           job,
           (executado_em at time zone 'America/Sao_Paulo')::date as dia,
           coalesce(sucesso, false) as sucesso,
           mensagem
    from public.ml_cron_log
    where executado_em > now() - interval '10 days'
      and job like 'diario_%'
    order by job, (executado_em at time zone 'America/Sao_Paulo')::date, executado_em desc
  ),
  streak as (
    -- dias consecutivos falhando, contados do dia mais recente pra trás
    select u.job,
           count(*) filter (where not u.sucesso) as dias_com_falha,
           max(u.dia) filter (where u.sucesso) as ultimo_dia_ok,
           (array_agg(u.mensagem order by u.dia desc) filter (where not u.sucesso))[1] as ultimo_erro,
           max(u.dia) as ultimo_dia
    from ult u group by u.job
  ),
  falhas as (
    select job, dias_com_falha, ultimo_dia_ok, ultimo_erro,
           -- dias seguidos falhando: desde o último OK até hoje
           coalesce(((now() at time zone 'America/Sao_Paulo')::date - ultimo_dia_ok), dias_com_falha) as dias_seguidos
    from streak
    where dias_com_falha > 0
  )
  select jsonb_build_object(
    'cron', coalesce((select jsonb_agg(jsonb_build_object(
       'job', job, 'sucesso', sucesso, 'horas_atras', horas_atras, 'msg', mensagem
     ) order by job) from public.ml_cron_saude), '[]'::jsonb),
    'cmv_cobertura_mes', public.ml_cmv_cobertura(p_month),
    -- NOVO: alerta de passo falhando >= 2 dias seguidos
    'alerta_passos_falhando', coalesce((
       select jsonb_agg(jsonb_build_object(
         'job', job, 'dias_seguidos', dias_seguidos,
         'ultimo_ok', ultimo_dia_ok, 'erro', ultimo_erro
       ) order by dias_seguidos desc)
       from falhas where dias_seguidos >= 2), '[]'::jsonb),
    'tem_alerta', exists (select 1 from falhas where dias_seguidos >= 2)
  );
$function$;

-- ============ ml_cron_diario — lock 421982739 + log honesto em TODOS os passos ============
CREATE OR REPLACE FUNCTION public.ml_cron_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_frete_ok boolean; v_frete_err text; v_rec_falhas int := 0;
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_t timestamptz; d date; i int;
  v_frete_grav int := 0; v_restam boolean := true; v_guard int := 0;
begin
  if not pg_try_advisory_lock(421982739) then
    return jsonb_build_object('skipped', 'already_running');
  end if;
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','fechar','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,valor,duracao_ms,mensagem,resposta)
  values ('diario_fechar', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'fechar'->>'upsertados')::int, (v_res->'body'->'fechar'->>'valorDia')::numeric,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'http_status')='200' then 'ok'
               else coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                             'HTTP '||coalesce(v_res->>'http_status','?')) end, v_res);

  v_t := clock_timestamp();
  v_frete_ok := true; v_frete_err := null;
  while v_restam and v_guard < 25 loop
    v_res := ml_edge_call(jsonb_build_object('modo','frete','janela',30,'limite',250));
    if (v_res->>'http_status') <> '200' then
      v_frete_ok := false;
      v_frete_err := coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                              'HTTP '||coalesce(v_res->>'http_status','?'));
      exit;  -- não finge que acabou: sai e loga a falha
    end if;
    v_frete_grav := v_frete_grav + coalesce((v_res->'body'->'frete'->>'gravados')::int, 0);
    v_restam := coalesce((v_res->'body'->'frete'->>'restam')::boolean, false);
    v_guard := v_guard + 1;
  end loop;
  -- estourar o guard com pendentes restando também é falha (não drenou tudo)
  if v_restam and v_guard >= 25 then
    v_frete_ok := false;
    v_frete_err := 'guard 25 chunks estourado com pendentes restando';
  end if;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_frete', v_ontem, v_frete_ok, v_frete_grav,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          coalesce(v_frete_err, 'chunks='||v_guard||' gravados='||v_frete_grav), v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','ads','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,duracao_ms,mensagem,resposta)
  values ('diario_ads', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'http_status')='200' then 'ok'
               else coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                             'HTTP '||coalesce(v_res->>'http_status','?')) end, v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','full'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_full', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'full'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'http_status')='200' then 'ok'
               else coalesce(v_res->'body'->>'detalhe', v_res->'body'->>'error',
                             'HTTP '||coalesce(v_res->>'http_status','?')) end, v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_passo('afiliados','CVAF','ml_afiliados');
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_afiliados', v_ontem, (v_res->>'completo')::boolean, (v_res->>'http_status')::int,
          (v_res->>'no_banco')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          coalesce(v_res->>'erro', v_res->>'aviso', 'ok'), v_res);

  -- DIFAL (CDIFAL) -- pesca ciclo atual + anterior, regua creation_date.
  v_t := clock_timestamp();
  v_res := ml_edge_passo('difal','CDIFAL','ml_difal');
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_difal', v_ontem, (v_res->>'completo')::boolean, (v_res->>'http_status')::int,
          (v_res->>'no_banco')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          coalesce(v_res->>'erro', v_res->>'aviso', 'ok'), v_res);

  -- NOVO: SEGUIDORES (CDLIT) -- campanha Publicidade "Aumentar seguidores".
  -- billing, regua creation_date, ciclo atual + anterior. Grava em ml_ads_diario
  -- (produto='seguidores') -> entra na linha ADS via ml_ads().
  v_t := clock_timestamp();
  v_res := ml_edge_passo('seguidores');
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_seguidores', v_ontem, (v_res->>'completo')::boolean, (v_res->>'http_status')::int,
          (v_res->'resposta'->'body'->'seguidores'->>'dias')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          coalesce(v_res->>'erro', v_res->>'aviso', 'ok'), v_res);

  -- BILLING (bonificações + fricção): BPAD abate o ADS; CXDED/CDSDB/CFPB/CXDID
  -- (menos os estornos espelho) viram a linha "Custo Devoluções". Régua creation_date
  -- mês-calendário -> pesca a fatura do mês atual e a anterior (ciclo fecha ~dia 22).
  -- ml_fill_billing confere contra o `total` da API e re-tenta (a API trunca em silêncio).
  v_t := clock_timestamp();
  v_res := ml_fill_billing(to_char((now() at time zone 'America/Sao_Paulo')::date, 'YYYY-MM-01'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_billing', v_ontem,
          ((v_res->>'ok')::boolean is true and coalesce((v_res->>'completo')::boolean, true)), (v_res->>'no_banco')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'ok')::boolean is not true then coalesce(v_res->>'erro','falhou')
               when (v_res->>'verificado')::boolean is not true then coalesce(v_res->>'aviso','nao verificado')
               when (v_res->>'completo')::boolean then 'ok'
               else coalesce(v_res->>'erro','INCOMPLETO') end, v_res);
  v_t := clock_timestamp();
  v_res := ml_fill_billing(to_char(((now() at time zone 'America/Sao_Paulo')::date - interval '1 month')::date, 'YYYY-MM-01'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_billing_ant', v_ontem,
          ((v_res->>'ok')::boolean is true and coalesce((v_res->>'completo')::boolean, true)), (v_res->>'no_banco')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'ok')::boolean is not true then coalesce(v_res->>'erro','falhou')
               when (v_res->>'verificado')::boolean is not true then coalesce(v_res->>'aviso','nao verificado')
               when (v_res->>'completo')::boolean then 'ok'
               else coalesce(v_res->>'erro','INCOMPLETO') end, v_res);

  v_t := clock_timestamp();
  v_rec_falhas := 0;
  for i in 0..6 loop
    d := v_ontem - i;
    v_res := ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',d::text));
    if (v_res->>'http_status') <> '200' then v_rec_falhas := v_rec_falhas + 1; end if;
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('diario_reconferir7', v_ontem, (v_rec_falhas = 0),
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when v_rec_falhas = 0 then '7 dias'
               else v_rec_falhas||' de 7 dias FALHARAM' end);

  perform pg_advisory_unlock(421982739);
  return jsonb_build_object('ontem', v_ontem, 'frete_gravados', v_frete_grav, 'frete_chunks', v_guard);
end $function$;
