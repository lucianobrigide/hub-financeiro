-- crons_status: falhas das últimas 24h visíveis (incidente 05/08/2026).
--
-- ANTES o semáforo olhava só o ÚLTIMO run do pg_cron: uma falha de madrugada
-- recuperada manualmente (ou seguida de um run ok) sumia do painel. AGORA:
--   - cada cron carrega `falhas_24h` (contagem em cron.job_run_details),
--     `ultima_falha` ("DD/MM HH:MM — mensagem") e `recuperado_em` (quando o log
--     de aplicação registrou sucesso DEPOIS da falha — ex.: re-execução manual);
--   - semáforo: último run failed + recuperado depois → 'amarelo' (era vermelho
--     "cego" ou, pior, verde no run seguinte); rodou ok mas falhou nas últimas
--     24h → 'amarelo';
--   - topo ganha `falhas_24h` total.
-- Catálogo de jobs e demais regras inalterados.

CREATE OR REPLACE FUNCTION public.crons_status()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'cron', 'extensions'
AS $function$
  with catalogo(jobname, plataforma, categoria, horario, o_que_faz, confiab_log, atraso_ok_horas, log_conta) as (values
    ('ml-diario','Mercado Livre','diario','Todo dia às 03:00 BRT',
     'Puxa as vendas de ontem do Mercado Livre, calcula todas as taxas (comissão, frete, ADS, afiliados, DIFAL) e a fatura completa, e atualiza a margem do dia. Também reconfere os pedidos dos últimos 7 dias pra pegar cancelamentos.',
     'honesto', 28, 'shopee_cron'),  -- ml não loga o run agregado em oauth_refresh_log; sem fallback util (fica no pg_cron)
    ('shopee-diario','Shopee','diario','Todo dia às 03:30 BRT',
     'Puxa os pedidos dos últimos 7 dias da Shopee, captura o repasse real (escrow) de cada um — inclusive os em trânsito — e calcula ADS e DIFAL. É o que mantém a margem da Shopee em dia.',
     'parcial', 28, 'shopee_cron'),
    ('tt-diario','TikTok','diario','Todo dia às 04:00 BRT',
     'Puxa os pedidos dos últimos 7 dias do TikTok e busca o financeiro de cada (comissão, taxas, frete). Pedido em trânsito fica na fila e é re-tentado todo dia até liquidar.',
     'honesto', 28, 'tt_cron'),
    ('az-diario','Amazon','diario','Todo dia às 03:15 BRT',
     'Puxa os pedidos de ontem da Amazon, estima comissão e frete na hora e confirma o valor real via Finances API em ~48h. Atualiza a margem do dia.',
     'honesto', 28, 'amazon_brigide'),
    ('azads-diario','Amazon','diario','Todo dia às 03:45 BRT',
     'Pede à Amazon o relatório de gasto de ADS por campanha dos últimos 3 dias (o valor flutua ~72h até fechar) e ingere o que ficou pronto. Uma colheita extra roda às 04:25 BRT (azads-colher) pra pegar relatório que a Amazon demora a gerar.',
     'honesto', 28, 'azads_brigide'),
    ('ml-semanal','Mercado Livre','semanal','Todo domingo às 05:00 BRT',
     'Reconferência longa: revisa os últimos 30 dias do Mercado Livre pra pegar cancelamentos e pedidos que fecharam tarde, que o diário (janela de 7 dias) não alcança.',
     'honesto', 192, null),
    ('shopee-semanal','Shopee','semanal','Todo domingo às 05:15 BRT',
     'Reconferência longa: revisa 30 dias da Shopee, atualiza status de cancelados/devolvidos e refina o repasse dos pedidos que liquidaram na semana.',
     'parcial', 192, 'shopee_cron_semanal'),
    ('tt-semanal','TikTok','semanal','Todo domingo às 05:45 BRT',
     'Reconferência longa: revisa 30 dias do TikTok e completa o financeiro dos pedidos que liquidaram na semana.',
     'honesto', 192, 'tt_cron_semanal'),
    ('az-semanal','Amazon','semanal','Todo domingo às 05:30 BRT',
     'Reconferência longa: re-fecha 30 dias da Amazon e confirma comissão/frete pendentes via Finances API.',
     'honesto', 192, null),
    ('ml-refresh-token','Mercado Livre','token','A cada 30 minutos',
     'Mantém a conexão com o Mercado Livre viva, renovando o token de acesso antes de expirar. Se parar, o diário não consegue puxar dados.',
     'honesto', 2, null),
    ('shopee-token-keepalive','Shopee','token','A cada 3 horas',
     'Mantém a conexão com a Shopee viva (o token dura 4h). Se parar, a captura de pedidos e repasse falha.',
     'honesto', 5, null),
    ('tt-token-keepalive','TikTok','token','Todo dia às 04:00 BRT',
     'Mantém a conexão com o TikTok viva, renovando o token de acesso.',
     'honesto', 28, null),
    ('tiny-token-keepalive','B2B / TINY','token','A cada 4 horas',
     'Mantém a conexão com o TINY (ERP das vendas internas/B2B) viva. Base pra automação futura do B2B.',
     'honesto', 6, null)
  ),
  ult_pg as (
    select distinct on (j.jobname)
      j.jobname, j.active, d.status as pg_status, d.start_time,
      round(extract(epoch from (d.end_time - d.start_time))::numeric, 1) as duracao_seg
    from cron.job j
    left join cron.job_run_details d on d.jobid = j.jobid
    order by j.jobname, d.start_time desc nulls last
  ),
  -- falhas nas últimas 24h (independente do último run ter sido ok)
  falhas24 as (
    select j.jobname,
           count(*) as falhas_24h,
           max(d.start_time) as ultima_falha_em,
           (array_agg(left(regexp_replace(d.return_message, '\s+', ' ', 'g'), 200)
                      order by d.start_time desc))[1] as ultima_falha_msg
    from cron.job j
    join cron.job_run_details d on d.jobid = j.jobid
    where d.status = 'failed' and d.start_time >= now() - interval '24 hours'
    group by j.jobname
  ),
  -- fallback: último run bem-sucedido no log de aplicação (só p/ crons com log_conta)
  ult_log as (
    select c.jobname,
           (select max(o.created_at) from oauth_refresh_log o
             where o.conta = c.log_conta and o.success is true) as log_start
    from catalogo c where c.log_conta is not null
  ),
  linhas as (
    select
      c.jobname, c.plataforma, c.categoria, c.horario, c.o_que_faz, c.confiab_log,
      coalesce(u.active, false) as ativo,
      u.pg_status, u.duracao_seg,
      -- fonte do "quando rodou": pg_cron se tiver; senão o log de app
      coalesce(u.start_time, l.log_start) as start_time,
      (u.start_time is null and l.log_start is not null) as via_log,
      extract(epoch from (now() - coalesce(u.start_time, l.log_start)))/3600 as horas_atras,
      coalesce(f.falhas_24h, 0) as falhas_24h,
      f.ultima_falha_em, f.ultima_falha_msg,
      -- recuperado: o log de aplicação registrou sucesso DEPOIS do último run
      -- falho do pg_cron (ex.: re-execução manual do job)
      case when u.pg_status = 'failed' and l.log_start > u.start_time
           then l.log_start end as recuperado_em
    from catalogo c
    left join ult_pg u on u.jobname = c.jobname
    left join ult_log l on l.jobname = c.jobname
    left join falhas24 f on f.jobname = c.jobname
  ),
  final as (
    select *,
      case
        when start_time is null then 'amarelo'
        -- falhou mas o log de app mostra sucesso posterior: atenção, não alarme
        when pg_status = 'failed' and recuperado_em is not null then 'amarelo'
        when pg_status = 'failed' then 'vermelho'
        when horas_atras > (select atraso_ok_horas from catalogo c where c.jobname = linhas.jobname) then 'amarelo'
        -- último run ok, mas houve falha nas últimas 24h: não deixar passar batido
        when falhas_24h > 0 then 'amarelo'
        -- rodou ok (pg_cron succeeded) OU só temos o log (via_log): trata como sucesso,
        -- mas se o log é suspeito, no máximo amarelo.
        else case when confiab_log = 'suspeito' then 'amarelo' else 'verde' end
      end as semaforo
    from linhas
  )
  select jsonb_build_object(
    'gerado_em', to_char(now() at time zone 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
    'total', (select count(*) from final),
    'verdes', (select count(*) from final where semaforo='verde'),
    'amarelos', (select count(*) from final where semaforo='amarelo'),
    'vermelhos', (select count(*) from final where semaforo='vermelho'),
    'falhas_24h', (select coalesce(sum(falhas_24h), 0) from final),
    'crons', (select jsonb_agg(jsonb_build_object(
        'jobname', jobname, 'plataforma', plataforma, 'categoria', categoria,
        'horario', horario, 'o_que_faz', o_que_faz, 'ativo', ativo,
        'confiab_log', confiab_log, 'semaforo', semaforo,
        'pg_status', case when via_log then 'succeeded' else pg_status end,
        'via_log', via_log,
        'ultima_exec', case when start_time is not null
          then to_char(start_time at time zone 'America/Sao_Paulo','DD/MM HH24:MI') end,
        'horas_atras', case when horas_atras is not null then round(horas_atras::numeric,1) end,
        'duracao_seg', duracao_seg,
        'falhas_24h', falhas_24h,
        'ultima_falha', case when ultima_falha_em is not null
          then to_char(ultima_falha_em at time zone 'America/Sao_Paulo','DD/MM HH24:MI')
               || coalesce(' — ' || ultima_falha_msg, '') end,
        'recuperado_em', case when recuperado_em is not null
          then to_char(recuperado_em at time zone 'America/Sao_Paulo','DD/MM HH24:MI') end
      ) order by
        case categoria when 'diario' then 1 when 'semanal' then 2 else 3 end, plataforma)
      from final)
  );
$function$;
