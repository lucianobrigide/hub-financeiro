// omie-despesas — gateway ÚNICO de leitura da API Omie (módulo Despesas).
//
// Toda leitura da Omie passa por aqui: autenticação (secrets via RPC de custódia),
// retry com backoff e paginação. Não expõe app_key/app_secret ao cliente.
//
// Body (POST, todos opcionais):
//   { call?, endpoint?, param?, fetchAll?, maxPaginas?, persist?, registrosPorPagina?,
//     filtrar_por_data_de?, filtrar_por_data_ate? }
// Padrão: call=ListarContasPagar, endpoint=financas/contapagar/, 1 página, persist=false.
// fetchAll=true varre todas as páginas (respeitando maxPaginas). persist=true faz upsert em omie_despesas.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OMIE_BASE = "https://app.omie.com.br/api/v1/";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// DD/MM/YYYY -> YYYY-MM-DD (ou null)
function toISO(d?: string | null): string | null {
  if (!d || !/^\d{2}\/\d{2}\/\d{4}$/.test(d)) return null;
  const [dd, mm, yy] = d.split("/");
  return `${yy}-${mm}-${dd}`;
}

// Chamada à Omie com retry (3 tentativas, backoff). Omie sinaliza erro com faultstring (HTTP 500).
async function omieCall(
  endpoint: string,
  call: string,
  appKey: string,
  appSecret: string,
  param: Record<string, unknown>,
): Promise<any> {
  let lastErr = "";
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const res = await fetch(OMIE_BASE + endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ call, app_key: appKey, app_secret: appSecret, param: [param] }),
      });
      const text = await res.text();
      let json: any = null;
      try { json = JSON.parse(text); } catch { /* corpo não-JSON */ }
      if (res.ok && json && !json.faultstring) return json;
      lastErr = json?.faultstring ? `${json.faultcode ?? ""} ${json.faultstring}` : `HTTP ${res.status} ${text.slice(0, 300)}`;
      // 4xx de credencial/param não adianta repetir
      if (json?.faultstring && /invalid|inválid|não.*permit|acesso/i.test(json.faultstring)) break;
    } catch (e) {
      lastErr = String(e);
    }
    if (attempt < 3) await sleep(600 * attempt);
  }
  throw new Error(`Omie ${call} falhou: ${lastErr}`);
}

function mapRow(r: any) {
  return {
    codigo_lancamento_omie: r.codigo_lancamento_omie,
    codigo_cliente_fornecedor: r.codigo_cliente_fornecedor ?? null,
    codigo_categoria: r.codigo_categoria ?? null,
    valor: r.valor_documento ?? null,
    data_emissao: toISO(r.data_emissao),
    data_vencimento: toISO(r.data_vencimento),
    // data_pagamento não vem no ListarContasPagar — enriquecer depois.
    status_titulo: r.status_titulo ?? null,
    numero_documento: r.numero_documento ?? null,
    raw: r,
    updated_at: new Date().toISOString(),
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "use POST" }), { status: 405, headers: { "Content-Type": "application/json" } });
  }
  try {
    const body = await req.json().catch(() => ({}));
    const endpoint = body.endpoint ?? "financas/contapagar/";
    const call = body.call ?? "ListarContasPagar";
    const registrosPorPagina = Math.min(Number(body.registrosPorPagina ?? 500), 500);
    const fetchAll = body.fetchAll === true;
    const maxPaginas = Number(body.maxPaginas ?? (fetchAll ? 10000 : 1));
    const persist = body.persist === true;

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Credenciais via RPC de custódia (nunca no código nem no cliente).
    const { data: cred, error: credErr } = await supabase.rpc("omie_get_credentials");
    if (credErr || !cred?.app_key || !cred?.app_secret) {
      return new Response(JSON.stringify({ error: "credenciais Omie indisponíveis", detail: credErr?.message }), {
        status: 500, headers: { "Content-Type": "application/json" },
      });
    }

    const baseParam: Record<string, unknown> = {
      registros_por_pagina: registrosPorPagina,
      apenas_importado_api: "N",
      ...(body.param ?? {}),
    };
    if (body.filtrar_por_data_de) baseParam.filtrar_por_data_de = body.filtrar_por_data_de;
    if (body.filtrar_por_data_ate) baseParam.filtrar_por_data_ate = body.filtrar_por_data_ate;

    let pagina = Number(body.param?.pagina ?? 1);
    let totalPaginas = 1;
    let totalRegistros = 0;
    let coletados = 0;
    let upserted = 0;
    const amostra: any[] = [];

    do {
      const resp = await omieCall(endpoint, call, cred.app_key, cred.app_secret, { ...baseParam, pagina });
      totalPaginas = resp.total_de_paginas ?? 1;
      totalRegistros = resp.total_de_registros ?? 0;
      const registros: any[] = resp.conta_pagar_cadastro ?? [];
      coletados += registros.length;
      if (amostra.length < 3) amostra.push(...registros.slice(0, 3 - amostra.length));

      if (persist && registros.length) {
        const rows = registros.map(mapRow);
        const { error: upErr } = await supabase
          .from("omie_despesas")
          .upsert(rows, { onConflict: "codigo_lancamento_omie" });
        if (upErr) throw new Error(`upsert omie_despesas: ${upErr.message}`);
        upserted += rows.length;
      }
      pagina++;
    } while (fetchAll && pagina <= totalPaginas && pagina <= maxPaginas);

    return new Response(JSON.stringify({
      ok: true,
      call,
      total_de_paginas: totalPaginas,
      total_de_registros: totalRegistros,
      paginas_lidas: pagina - 1,
      registros_coletados: coletados,
      persistidos: persist ? upserted : 0,
      amostra: persist ? undefined : amostra,
    }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String((e as Error).message ?? e) }), {
      status: 502, headers: { "Content-Type": "application/json" },
    });
  }
});
