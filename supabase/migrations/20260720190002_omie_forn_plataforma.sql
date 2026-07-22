-- Fornecedores de PLATAFORMA: pagamentos que o Hub já captura (ex.: Mercado Pago = ADS/Full
-- de ML, pagos direto na conta corrente). Movimentos desses fornecedores ficam FORA do DRE
-- mesmo sendo "genuínos" (n_cod_titulo=0), pra não duplicar o que o Hub já traz.
CREATE TABLE IF NOT EXISTS public.omie_forn_plataforma (
  codigo_cliente bigint PRIMARY KEY,
  nome text
);
ALTER TABLE public.omie_forn_plataforma ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.omie_forn_plataforma TO service_role;
INSERT INTO public.omie_forn_plataforma (codigo_cliente, nome)
VALUES (10708043800, 'Mercado Pago — ADS/Full de plataforma ML (o Hub já captura)')
ON CONFLICT (codigo_cliente) DO UPDATE SET nome = EXCLUDED.nome;

-- Bônus: data de pagamento (baixa) dos títulos de AP vem dos movimentos vinculados (nCodTitulo).
UPDATE public.omie_despesas d
SET data_pagamento = mc.data_pagamento
FROM public.omie_mov_cc mc
WHERE mc.n_cod_titulo = d.codigo_lancamento_omie AND d.data_pagamento IS NULL AND mc.data_pagamento IS NOT NULL;
