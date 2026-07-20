-- Onboarding Omie — módulo Despesas. Tabela de contas a pagar.
-- Grão = título/parcela (codigo_lancamento_omie é único por parcela).
-- Campos mínimos do onboarding + raw JSON completo pra não perder nada.
CREATE TABLE IF NOT EXISTS public.omie_despesas (
  codigo_lancamento_omie    bigint PRIMARY KEY,          -- id Omie (título/parcela)
  codigo_cliente_fornecedor bigint,                      -- fornecedor (CÓDIGO; nome via ListarClientes depois)
  fornecedor_nome           text,                        -- enriquecido depois (nulo no onboarding)
  codigo_categoria          text,                        -- categoria Omie (ex.: "2.01.01")
  valor                     numeric(14,2),               -- valor_documento
  data_emissao              date,
  data_vencimento           date,
  data_pagamento            date,                         -- NÃO vem no Listar; enriquecer via ConsultarContaPagar
  status_titulo             text,                         -- PAGO / ATRASADO / A VENCER / CANCELADO ...
  numero_documento          text,                         -- útil p/ conciliação
  raw                       jsonb NOT NULL,               -- registro cru completo
  ingested_at               timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.omie_despesas IS
  'Contas a pagar (despesas) da Omie via ListarContasPagar. Grão = título/parcela. '
  'data_pagamento e fornecedor_nome não vêm no Listar — enriquecer depois (ConsultarContaPagar / ListarClientes).';

CREATE INDEX IF NOT EXISTS omie_despesas_emissao_idx    ON public.omie_despesas(data_emissao);
CREATE INDEX IF NOT EXISTS omie_despesas_vencimento_idx ON public.omie_despesas(data_vencimento);
CREATE INDEX IF NOT EXISTS omie_despesas_status_idx     ON public.omie_despesas(status_titulo);
CREATE INDEX IF NOT EXISTS omie_despesas_fornecedor_idx ON public.omie_despesas(codigo_cliente_fornecedor);

-- Padrão do hub: acesso só via service_role (RLS liga, sem policies = nega anon/authenticated).
-- Tabela criada via Management API fica fora das default privileges → GRANT explícito ao service_role.
ALTER TABLE public.omie_despesas ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.omie_despesas TO service_role;
