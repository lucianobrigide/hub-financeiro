-- Cache de nomes de fornecedores (ConsultarCliente é 1 chamada por código; guardamos aqui)
-- pro drill-down de item unitário mostrar o nome, não o código.
CREATE TABLE IF NOT EXISTS public.omie_fornecedores (
  codigo_cliente bigint PRIMARY KEY,
  razao_social   text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.omie_fornecedores ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.omie_fornecedores TO service_role;

-- Resolve nomes dos fornecedores do DRE (AP + mov_cc) ainda não cacheados. Resiliente:
-- se uma chamada falhar/travar, grava nome nulo e segue (não derruba o lote).
CREATE OR REPLACE FUNCTION public.omie_fill_fornecedores(p_limit int)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions'
AS $function$
DECLARE v_key text; v_sec text; v_cod bigint; v_done int := 0; v_fail int := 0; v_nome text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name='omie_app_key';
  SELECT decrypted_secret INTO v_sec FROM vault.decrypted_secrets WHERE name='omie_app_secret';
  FOR v_cod IN
    SELECT forn FROM (
      SELECT codigo_cliente_fornecedor forn FROM public.omie_despesas WHERE codigo_cliente_fornecedor IS NOT NULL
      UNION
      SELECT n_cod_cliente FROM public.omie_mov_cc WHERE n_cod_cliente IS NOT NULL
    ) t
    WHERE NOT EXISTS (SELECT 1 FROM public.omie_fornecedores f WHERE f.codigo_cliente = t.forn)
    LIMIT p_limit
  LOOP
    BEGIN
      v_nome := (extensions.http_post('https://app.omie.com.br/api/v1/geral/clientes/',
        jsonb_build_object('call','ConsultarCliente','app_key',v_key,'app_secret',v_sec,
          'param',jsonb_build_array(jsonb_build_object('codigo_cliente_omie',v_cod)))::text,
        'application/json')).content::jsonb ->> 'razao_social';
    EXCEPTION WHEN OTHERS THEN
      v_nome := NULL; v_fail := v_fail + 1;
    END;
    INSERT INTO public.omie_fornecedores (codigo_cliente, razao_social) VALUES (v_cod, v_nome)
    ON CONFLICT (codigo_cliente) DO UPDATE SET razao_social=excluded.razao_social, updated_at=now();
    v_done := v_done + 1;
  END LOOP;
  RETURN jsonb_build_object('processados', v_done, 'falhas_http', v_fail, 'no_cache', (SELECT count(*) FROM public.omie_fornecedores));
END $function$;
GRANT EXECUTE ON FUNCTION public.omie_fill_fornecedores(int) TO service_role;
