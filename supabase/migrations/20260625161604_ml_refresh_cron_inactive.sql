-- Passo 7 da receita: cron proativo, criado INATIVO. Ativar só no cutover (Passo 9.6):
--   select cron.alter_job((select jobid from cron.job where jobname='ml-refresh-token'), active := true);
do $$
declare jid bigint;
begin
  if not exists (select 1 from cron.job where jobname = 'ml-refresh-token') then
    jid := cron.schedule('ml-refresh-token', '*/30 * * * *', 'select public.ml_refresh_token(false);');
    perform cron.alter_job(job_id := jid, active := false);
  end if;
end $$;
