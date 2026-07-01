-- Log dedicado dos disparos do cron de ingestão (visibilidade "rodou/falhou/quantos").
-- Cada disparo grava a resposta REAL da Edge (nº pedidos, valor, http status, corpo bruto).
-- cron.job_run_details só diz "succeeded/1 row" — não conta o resultado de negócio.
create table if not exists public.ml_cron_log (
  id            bigint generated always as identity primary key,
  executado_em  timestamptz not null default now(),
  job           text        not null,             -- 'fechar_ontem' | 'reconferir_dia' | ...
  dia_alvo      date,                              -- dia processado
  sucesso       boolean     not null,
  http_status   int,
  pedidos       int,                               -- nº de pedidos upsertados pela Edge
  valor         numeric(14,2),                     -- valor do dia (quando aplicável)
  duracao_ms    int,
  mensagem      text,                              -- 'ok' | motivo recusa | erro resumido
  resposta      jsonb                              -- corpo bruto da Edge (auditoria)
);

create index if not exists ml_cron_log_job_exec_idx on public.ml_cron_log (job, executado_em desc);

-- RLS on sem policies (padrão do projeto). A função de cron é SECURITY DEFINER → grava.
alter table public.ml_cron_log enable row level security;
