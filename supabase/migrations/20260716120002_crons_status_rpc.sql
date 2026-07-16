-- Página "Crons": RPC crons_status() — saúde de todos os cron jobs que alimentam o dashboard.
--
-- DESENHO: o SEMÁFORO vem de cron.job_run_details (o pg_cron não mente sobre disparar/estourar
-- — foi ele que denunciou o ml-diario 'failed' enquanto o log de app dizia 'ok'). O DETALHE e a
-- confiabilidade vêm do log de aplicação. Fallback: quando o pg_cron já não guarda o run (retém
-- ~4 dias — os semanais saem da janela no meio da semana), usa o log de app pra dizer "rodou tal
-- dia" (via_log=true), sem fingir confirmação do agendador.
--
-- confiab_log: honesto | parcial | suspeito. semaforo: verde | amarelo | vermelho.
-- Leitura pura; o front consome só esta RPC (nunca toca no schema cron.* direto).
-- Capturado via pg_get_functiondef (repo == banco).

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
     'Puxa os pedidos de ontem da Amazon, estima comissão e frete na hora e confirma o valor real via Finances API em ~48h. Atualiza a margem do dia. (ADS ainda não é capturado.)',
     'honesto', 28, 'amazon_brigide'),
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
      extract(epoch from (now() - coalesce(u.start_time, l.log_start)))/3600 as horas_atras
    from catalogo c
    left join ult_pg u on u.jobname = c.jobname
    left join ult_log l on l.jobname = c.jobname
  ),
  final as (
    select *,
      case
        when start_time is null then 'amarelo'
        when pg_status = 'failed' then 'vermelho'
        when horas_atras > (select atraso_ok_horas from catalogo c where c.jobname = linhas.jobname) then 'amarelo'
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
    'crons', (select jsonb_agg(jsonb_build_object(
        'jobname', jobname, 'plataforma', plataforma, 'categoria', categoria,
        'horario', horario, 'o_que_faz', o_que_faz, 'ativo', ativo,
        'confiab_log', confiab_log, 'semaforo', semaforo,
        'pg_status', case when via_log then 'succeeded' else pg_status end,
        'via_log', via_log,
        'ultima_exec', case when start_time is not null
          then to_char(start_time at time zone 'America/Sao_Paulo','DD/MM HH24:MI') end,
        'horas_atras', case when horas_atras is not null then round(horas_atras::numeric,1) end,
        'duracao_seg', duracao_seg
      ) order by
        case categoria when 'diario' then 1 when 'semanal' then 2 else 3 end, plataforma)
      from final)
  );
$function$;
