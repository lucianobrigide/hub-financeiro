-- ML — INGESTAO DA FATURA COMPLETA (billing): bonificacoes + taxas de fricao.
--
-- LACUNA ESTRUTURAL FECHADA: o Hub pescava so linhas isoladas do billing (CVAF, CDIFAL,
-- CDLIT) e o ADS vinha da API de delivery (BRUTO). Ignorava dezenas de outros tipos —
-- inclusive CREDITOS que o ML devolve. Auditoria de 35 sub_types (ver Notion "ML —
-- AUDITORIA DE ANCORAGEM"). Junho/2026: M.C. 144.663,14 -> 151.976,82 (+7.313,68).
--
-- O QUE ENTRA:
--   BPAD  = "Bonificacao campanhas Product Ads" -> CREDITA o ADS (bruto - BPAD).
--           Junho: bruto 225.387,87 - 15.265,87 = liquido 210.122,00.
--   CXDED/CDSDB/CFPB/CXDID (debitos de devolucao/inconformidade) MENOS os estornos
--           espelho BXDED/BDSDB/BXDID -> linha "Custo Devolucoes" LIQUIDA (analoga a
--           Shopee). Junho: 8.840,04 - 887,85 = 7.952,19 (208 lancamentos).
--
-- O QUE **NAO** ENTRA (verificado, nao suposto):
--   CFONPN (154.774,95) = "Taxa de parcelamento (equivalente ao acrescimo pago pelo
--           comprador)" -> PASS-THROUGH net-zero. PROVA no relatorio oficial de Vendas:
--           receita por acrescimo +158.923,54 e taxa equivalente -158.923,54 = 0,00 exato.
--           Ingerir so o custo deixaria a M.C. R$154.775 pessimista.
--   CVVPRC (45.898) / CVVFNU (1.791) -> JA estao dentro do sale_fee. PROVA ao centavo,
--           pedido a pedido: sale_fee = CVVML + CVVPRC + CVVFNU (ex.: 14,85+6,77+0,70
--           = 22,32 = sale_fee). Adicionar = dupla contagem de ~R$40k.
--   BVVML/BFFE/BVVPRC/BVVFNU -> ja tratados pela regua paid+partially_refunded (venda
--           cancelada sai inteira; creditar o estorno por cima = dupla contagem).
--   CXDE -> e FRETE, nao fricao: transaction_detail identico ao do CFFE, ticket ~R$28,88,
--           400/400 com shipping_id ja no ml_envios. O salto 876 -> 61.088 no ciclo 07 e o
--           ML migrando o sub_type de frete CFFE -> CXDE em ~24/06 (CFFE caiu no mesmo
--           ciclo). O frete do Hub vem da API de shipments -> nao afeta. Entrar = +R$61k
--           de dupla contagem.
--
-- REGUA: creation_date, mes-calendario (igual CVAF/CDIFAL/CDLIT). O ciclo ~fecha dia 22,
-- entao um mes vem de 2 faturas -> o cron pesca mesKey(0) + mesKey(-1). Idempotente por
-- detail_id.
--
-- ACHADO CRITICO — A API DE BILLING TRUNCA EM SILENCIO: vista ao vivo devolvendo 50 de 250
-- registros com HTTP 200 e sem erro. Sem conferir, o mes fica incompleto e a M.C. sai
-- errada SEM AVISO. Por isso ml_fill_billing confere o que gravou contra o `total` da API
-- e refaz o walk (from_id=0, idempotente) ate bater — max 4 tentativas — e devolve
-- completo:true/false. O cron loga "INCOMPLETO (API truncou)" quando nao fecha.
--
-- PEGADINHAS DA API (custaram tempo, ficam registradas):
--   - `document_type` e OBRIGATORIO (senao 422).
--   - o filtro e `detail_sub_types` (PLURAL). O singular `detail_sub_type` e IGNORADO
--     silenciosamente (devolve tudo). `order_id` tambem e ignorado.
--   - paginacao: `from_id` (EXCLUSIVO) + sort_by=ID&order_by=ASC. `offset` e `last_id`
--     sao IGNORADOS — offset alto devolve vazio.
--   - o endpoint e lento: precisa http_set_curlopt CURLOPT_TIMEOUT_MS (o default do PG
--     de 5s estoura).
--
-- NOTA DE PADRAO: a ingestao sai do PG (nao da Edge). O padrao ML usa Edge nos modos
-- pesados (orders, 150s), mas billing e leve e o PG chama a API do ML sem problema
-- (mesmo padrao da Shopee) — evita um deploy de Edge so pra isso.
--
-- Definicoes capturadas via pg_get_functiondef (repo == banco).

CREATE TABLE IF NOT EXISTS public.ml_billing_linhas (
  detail_id        bigint PRIMARY KEY,
  creation_date    date NOT NULL,
  creation_date_time timestamptz,
  detail_type      text,          -- CHARGE | BONUS
  detail_sub_type  text NOT NULL, -- BPAD, CXDED, CDSDB, CFPB, CXDID, BXDED, BDSDB, BXDID
  detail_amount    numeric NOT NULL,
  transaction_detail text,
  order_id         bigint,
  periodo_key      text,
  atualizado_em    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ml_billing_linhas_data_tipo_idx
  ON public.ml_billing_linhas (creation_date, detail_sub_type);
ALTER TABLE public.ml_billing_linhas ENABLE ROW LEVEL SECURITY;

-- ============ ml_fill_billing — ingestao auto-cicatrizante ============
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
  v_try int := 0;
  v_tipos text := 'BPAD,CXDED,CDSDB,CFPB,CXDID,BXDED,BDSDB,BXDID';
BEGIN
  SELECT (public.ml_get_state()).access_token INTO v_tok;
  IF v_tok IS NULL THEN RETURN jsonb_build_object('error','sem_token'); END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','60000');

  <<tentativas>>
  LOOP
    v_try := v_try + 1;
    v_from := 0; v_page := 0; v_grav := 0;

    LOOP
      v_page := v_page + 1;
      EXIT WHEN v_page > 60;
      SELECT (r.content::jsonb) INTO v_resp
      FROM extensions.http((
        'GET',
        'https://api.mercadolibre.com/billing/integration/periods/key/'||p_key||
        '/group/ML/details?document_type=BILL&detail_sub_types='||v_tipos||
        '&limit=500&from_id='||v_from||'&sort_by=ID&order_by=ASC',
        ARRAY[extensions.http_header('Authorization','Bearer '||v_tok)], NULL, NULL
      )::extensions.http_request) r;

      IF v_total_api IS NULL THEN v_total_api := (v_resp->>'total')::int; END IF;
      v_res := v_resp->'results';
      EXIT WHEN v_res IS NULL OR jsonb_array_length(v_res) = 0;

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
    EXIT tentativas WHEN v_total_api IS NULL OR v_no_banco >= v_total_api OR v_try >= 4;
  END LOOP;

  RETURN jsonb_build_object('key', p_key, 'gravados_ultima_passada', v_grav,
    'total_api', v_total_api, 'no_banco', v_no_banco, 'tentativas', v_try,
    'completo', (v_total_api IS NOT NULL AND v_no_banco >= v_total_api));
END $function$;

-- ============ ml_ads — agora LIQUIDO (bruto - BPAD) ============
CREATE OR REPLACE FUNCTION public.ml_ads(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with bruto as (
    select coalesce(round(sum(gasto), 2), 0) as v
    from public.ml_ads_diario
    where to_char(data, 'YYYY-MM') = p_month
      and produto in ('product_ads', 'brand_ads', 'seguidores')
      and data < (now() at time zone 'America/Sao_Paulo')::date
  ),
  bonif as (
    -- BPAD vem POSITIVO no detail_amount (é BONUS); abate o bruto.
    select coalesce(round(sum(detail_amount), 2), 0) as v
    from public.ml_billing_linhas
    where to_char(creation_date, 'YYYY-MM') = p_month
      and detail_sub_type = 'BPAD'
  )
  select jsonb_build_object(
    'ads_total_mes',    (select v from bruto) - (select v from bonif),  -- LÍQUIDO
    'ads_bruto',        (select v from bruto),
    'ads_bonificacao',  (select v from bonif)
  );
$function$;

-- ============ ml_friccao — Custo Devolucoes/Fricao ML (liquido) ============
CREATE OR REPLACE FUNCTION public.ml_friccao(p_month text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with j as (
    select detail_sub_type, detail_amount
    from public.ml_billing_linhas
    where to_char(creation_date, 'YYYY-MM') = p_month
  )
  select jsonb_build_object(
    'friccao_total',  coalesce(round(
        sum(detail_amount) filter (where detail_sub_type in ('CXDED','CDSDB','CFPB','CXDID'))
      - sum(detail_amount) filter (where detail_sub_type in ('BXDED','BDSDB','BXDID')), 2), 0),
    'debitos',        coalesce(round(sum(detail_amount) filter (where detail_sub_type in ('CXDED','CDSDB','CFPB','CXDID')), 2), 0),
    'creditos',       coalesce(round(sum(detail_amount) filter (where detail_sub_type in ('BXDED','BDSDB','BXDID')), 2), 0),
    'lancamentos',    count(*) filter (where detail_sub_type in ('CXDED','CDSDB','CFPB','CXDID','BXDED','BDSDB','BXDID'))
  )
  from j;
$function$;

-- ============ ml_cron_diario — + passo diario_billing (2 faturas) ============
CREATE OR REPLACE FUNCTION public.ml_cron_diario()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_ontem date := (now() at time zone 'America/Sao_Paulo')::date - 1;
  v_res jsonb; v_t timestamptz; d date; i int;
  v_frete_grav int := 0; v_restam boolean := true; v_guard int := 0;
begin
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','fechar','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,valor,duracao_ms,mensagem,resposta)
  values ('diario_fechar', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'fechar'->>'upsertados')::int, (v_res->'body'->'fechar'->>'valorDia')::numeric,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  while v_restam and v_guard < 25 loop
    v_res := ml_edge_call(jsonb_build_object('modo','frete','janela',30,'limite',250));
    v_frete_grav := v_frete_grav + coalesce((v_res->'body'->'frete'->>'gravados')::int, 0);
    v_restam := coalesce((v_res->'body'->'frete'->>'restam')::boolean, false);
    v_guard := v_guard + 1;
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem)
  values ('diario_frete', v_ontem, true, v_frete_grav,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'chunks='||v_guard||' gravados='||v_frete_grav);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','ads','dia',v_ontem::text));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,duracao_ms,mensagem,resposta)
  values ('diario_ads', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','full'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_full', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'full'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','afiliados'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_afiliados', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'afiliados'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  -- DIFAL (CDIFAL) -- pesca ciclo atual + anterior, regua creation_date.
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','difal'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_difal', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'difal'->>'gravados')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  -- NOVO: SEGUIDORES (CDLIT) -- campanha Publicidade "Aumentar seguidores".
  -- billing, regua creation_date, ciclo atual + anterior. Grava em ml_ads_diario
  -- (produto='seguidores') -> entra na linha ADS via ml_ads().
  v_t := clock_timestamp();
  v_res := ml_edge_call(jsonb_build_object('modo','seguidores'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,http_status,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_seguidores', v_ontem, (v_res->>'http_status')='200', (v_res->>'http_status')::int,
          (v_res->'body'->'seguidores'->>'dias')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int, 'ok', v_res);

  -- BILLING (bonificações + fricção): BPAD abate o ADS; CXDED/CDSDB/CFPB/CXDID
  -- (menos os estornos espelho) viram a linha "Custo Devoluções". Régua creation_date
  -- mês-calendário -> pesca a fatura do mês atual e a anterior (ciclo fecha ~dia 22).
  -- ml_fill_billing confere contra o `total` da API e re-tenta (a API trunca em silêncio).
  v_t := clock_timestamp();
  v_res := ml_fill_billing(to_char((now() at time zone 'America/Sao_Paulo')::date, 'YYYY-MM-01'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_billing', v_ontem, (v_res->>'completo')::boolean, (v_res->>'no_banco')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'completo')::boolean then 'ok' else 'INCOMPLETO (API truncou)' end, v_res);
  v_t := clock_timestamp();
  v_res := ml_fill_billing(to_char(((now() at time zone 'America/Sao_Paulo')::date - interval '1 month')::date, 'YYYY-MM-01'));
  insert into public.ml_cron_log(job,dia_alvo,sucesso,pedidos,duracao_ms,mensagem,resposta)
  values ('diario_billing_ant', v_ontem, (v_res->>'completo')::boolean, (v_res->>'no_banco')::int,
          (extract(epoch from clock_timestamp()-v_t)*1000)::int,
          case when (v_res->>'completo')::boolean then 'ok' else 'INCOMPLETO (API truncou)' end, v_res);

  v_t := clock_timestamp();
  for i in 0..6 loop
    d := v_ontem - i;
    perform ml_edge_call(jsonb_build_object('modo','reconferir','reconferirDia',d::text));
  end loop;
  insert into public.ml_cron_log(job,dia_alvo,sucesso,duracao_ms,mensagem)
  values ('diario_reconferir7', v_ontem, true, (extract(epoch from clock_timestamp()-v_t)*1000)::int, '7 dias');

  return jsonb_build_object('ontem', v_ontem, 'frete_gravados', v_frete_grav, 'frete_chunks', v_guard);
end $function$;
