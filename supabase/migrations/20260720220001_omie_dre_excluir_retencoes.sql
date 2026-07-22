-- Impostos RETIDOS de terceiros (ISSQN, CSRF/PIS-COFINS-CSLL) NÃO são despesa: são retenção
-- que a empresa recolhe no lugar do prestador. O valor já está no bruto do serviço (que entra
-- como despesa); contar a retenção de novo duplica. Ficam FORA do DRE. (Luciano, 07/2026.)
UPDATE public.omie_dre_mapa
SET incluir=false, dre_code=null, dre_label='Retenção (não é despesa)',
    obs='ISSQN retido de terceiros = retenção, não despesa. Já está no valor bruto do serviço; contar de novo duplica.'
WHERE codigo_categoria='2.06.93';

INSERT INTO public.omie_dre_mapa (codigo_categoria, dre_code, dre_label, incluir, categoria_nome, obs)
VALUES ('2.06.92', null, 'Retenção (não é despesa)', false, 'CRFS retido 3º',
        'CSRF retido de terceiros (PIS/COFINS/CSLL na fonte) = retenção, não despesa — já está no bruto do serviço. Mesmo princípio do ISSQN retido.')
ON CONFLICT (codigo_categoria) DO UPDATE
  SET dre_code=EXCLUDED.dre_code, dre_label=EXCLUDED.dre_label, incluir=EXCLUDED.incluir,
      categoria_nome=EXCLUDED.categoria_nome, obs=EXCLUDED.obs;
