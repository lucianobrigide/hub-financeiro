-- DIFAL: a categoria 2.06.94 "ICMS DIFAL" era mista (plataforma + pago por fora). O Luciano
-- separou na Omie: criou 2.06.90 "ICMS DIFAL PLATAFORMA" (o DIFAL da plataforma, que o Hub já
-- captura em I1) e deixou a 2.06.94 só com o DIFAL pago por fora (direto aos estados).
--  * 2.06.94 -> entra na linha DIFAL (I1), somando com o DIFAL de plataforma do Hub.
--  * 2.06.90 -> fica de fora (incluir=false) pra não duplicar o que o Hub já traz.
UPDATE public.omie_dre_mapa
SET incluir = true, dre_code = 'I1', dre_label = 'DIFAL', categoria_nome = 'ICMS DIFAL (por fora)',
    obs = 'DIFAL pago por fora (direto aos estados: BA/RJ/MG/PE). Entra em DIFAL (I1) somando com o da plataforma (Hub).'
WHERE codigo_categoria = '2.06.94';

INSERT INTO public.omie_dre_mapa (codigo_categoria, dre_code, dre_label, incluir, categoria_nome, obs)
VALUES ('2.06.90', NULL, 'DIFAL Plataforma (Hub)', false, 'ICMS DIFAL Plataforma',
        'DIFAL da plataforma (ML) — o Hub já captura em I1; fica fora pra não duplicar')
ON CONFLICT (codigo_categoria) DO UPDATE
  SET dre_code = EXCLUDED.dre_code, dre_label = EXCLUDED.dre_label, incluir = EXCLUDED.incluir,
      categoria_nome = EXCLUDED.categoria_nome, obs = EXCLUDED.obs;
