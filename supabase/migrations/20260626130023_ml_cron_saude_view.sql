-- Saúde do cron: última execução por job + idade + status. Base pra alerta "algo parou".
create or replace view public.ml_cron_saude as
select distinct on (job)
  job, executado_em, sucesso, dia_alvo, pedidos, valor, duracao_ms, mensagem,
  round(extract(epoch from (now() - executado_em)) / 3600.0, 1) as horas_atras
from public.ml_cron_log
order by job, executado_em desc;

-- RPC de alerta consolidado (cron + cobertura CMV do mês)
create or replace function public.ml_saude(p_month text)
returns jsonb language sql security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'cron', coalesce((select jsonb_agg(jsonb_build_object(
       'job', job, 'sucesso', sucesso, 'horas_atras', horas_atras, 'msg', mensagem
     ) order by job) from public.ml_cron_saude), '[]'::jsonb),
    'cmv_cobertura_mes', public.ml_cmv_cobertura(p_month)
  );
$function$;

revoke all on function public.ml_saude(text) from public, anon, authenticated;
grant execute on function public.ml_saude(text) to service_role;
