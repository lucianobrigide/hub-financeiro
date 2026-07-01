-- Custo do produto (CMV — só a mercadoria), por SKU de venda.
-- Regulariza no repo a tabela que já existe e está populada no banco (32 SKUs).
-- O de-para variante->modelo JÁ está aplicado: cada SKU de cor tem seu custo, herdado
-- do modelo-base (coluna 'modelo'). 'origem' classifica a confiança do custo:
--   exato             = SKU de venda == SKU da planilha (custo direto)
--   confirmado        = variante mapeada ao modelo-base, conferido
--   proposto-prefixo  = variante mapeada por prefixo, a confirmar
-- Fonte dos custos: PRODUTOS.xlsx (gitignored, não versionado). RLS ligado sem policy.
create table if not exists public.ml_custo_produto (
  sku           text        not null,
  modelo        text        not null,
  custo         numeric     not null,
  origem        text        not null,
  atualizado_em timestamptz not null default now(),
  constraint ml_custo_produto_pkey primary key (sku),
  constraint ml_custo_produto_origem_check check (origem = any (array['confirmado','exato','proposto-prefixo']))
);
alter table public.ml_custo_produto enable row level security;

-- Seed idempotente dos custos atuais (UPSERT por sku).
insert into public.ml_custo_produto (sku, modelo, custo, origem) values
  ('3FRIGI_IVORY','3FRIG',49.00065,'proposto-prefixo'),
  ('3FRIGI_MARROM','3FRIG',49.00065,'proposto-prefixo'),
  ('cafe025','CAFITALIANA',41.53500,'confirmado'),
  ('DNF05BAUNILHAC','DNF05BAUNILHAC',248.14500,'exato'),
  ('DNF05GRAFITEC','DNF05GRAFITEC',248.14500,'exato'),
  ('FIRENZE08OXFORDFIORI','FIRENZE08OXFORDFIORI',138.45000,'exato'),
  ('FIRENZE10BIANCO','FIRENZE10',149.00415,'confirmado'),
  ('FIRENZE10CAPPU','FIRENZE10',149.00415,'confirmado'),
  ('FIRENZE10FIORI','FIRENZE10FIORI',144.99975,'exato'),
  ('FIRENZE10IVORY','FIRENZE10D',153.99900,'confirmado'),
  ('FIRENZE10MARROMD','FIRENZE10D',153.99900,'confirmado'),
  ('FIRENZE10ROSAD','FIRENZE10D',153.99900,'confirmado'),
  ('FRIG_OVO','FRIG_OVO',15.00000,'exato'),
  ('JARRAD14','JARRAD14',15.00000,'exato'),
  ('JG06MANAUS','JG06MANAUS',250.00000,'exato'),
  ('JG08IBIZA','JG08IBIZA',350.00000,'exato'),
  ('JG6BRUXELAS','JG6BRUXELAS',290.00000,'exato'),
  ('MARPAL10CEREJA','MARPAL10',134.20065,'confirmado'),
  ('MARPAL10PRETO','MARPAL10',134.20065,'confirmado'),
  ('MARPAL10PRETOB','MARPAL10',134.20065,'confirmado'),
  ('MARPAL10ROSE','MARPAL10',134.20065,'confirmado'),
  ('MARPAL17BIANCO','MARPAL17',275.00430,'proposto-prefixo'),
  ('MARPAL17PRETO','MARPAL17',275.00430,'proposto-prefixo'),
  ('MARPAL9AMARELO','MARPAL9',127.59765,'confirmado'),
  ('MARPAL9PRETO','MARPAL9',127.59765,'confirmado'),
  ('MARPAL9PRETOB','MARPAL9',127.59765,'confirmado'),
  ('MARPAL9ROSE','MARPAL9',127.59765,'confirmado'),
  ('MARPALCACAP','MARPALCACA',126.50070,'proposto-prefixo'),
  ('MARPALCACAR','MARPALCACA',126.50070,'proposto-prefixo'),
  ('PANP_45_ARN','PANP_45_ARN',85.20000,'exato'),
  ('PP45_CR_ARX','PP45_CR_ARX',85.20000,'exato'),
  ('PP45_VM_ARX','PP45_VM_ARX',85.20000,'exato')
on conflict (sku) do update set
  modelo = excluded.modelo,
  custo  = excluded.custo,
  origem = excluded.origem,
  atualizado_em = now();
