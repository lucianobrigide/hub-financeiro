import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Ingestão do gasto Amazon Ads (Reports v3, assíncrono). Modos:
//   pedir  {de, ate} — cria relatórios DAILY por campanha (SP/SB/SD) e registra na fila
//   colher           — consulta jobs PENDENTES; COMPLETED → baixa (gzip) e grava via
//                      azads_replace_gastos; FAILED → marca FALHOU. Pendente é estado
//                      honesto: não é sucesso nem falha.
//   ciclo  {de, ate} — colher + pedir (usado pelo cron diário, janela D-3..D-1)
// Auth: x-api-key (azads_token_key no Vault). Token LwA via azads_get_state/refresh.
// Validado 03/08/2026: julho SP pela API = painel centavo a centavo (R$ 14.125,85).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ADS_API = "https://advertising-api.amazon.com";
const CLIENT_ID = "amzn1.application-oa2-client.3ded0d38c5404a8fb3c24f33c761914a";
const SKEW_MS = 10 * 60 * 1000;
const PRODUCTS: Array<[string, string]> = [
  ["SPONSORED_PRODUCTS", "spCampaigns"],
  ["SPONSORED_BRANDS", "sbCampaigns"],
  ["SPONSORED_DISPLAY", "sdCampaigns"],
];

const restHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function rpc<T>(fn: string, body: unknown): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: restHeaders, body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`rpc ${fn}: ${r.status} ${await r.text()}`);
  // RPCs void respondem 204 sem corpo — json() estouraria
  const text = await r.text();
  return (text ? JSON.parse(text) : null) as T;
}

async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  return (await rpc<boolean>("azads_token_check", { p_key: candidate }).catch(() => false)) === true;
}

type State = { access_token: string | null; expires_at: string | null; profile_id: string | null };
const isFresh = (s: State | null) =>
  !!s?.access_token && !!s.expires_at && new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;

async function getAuth(): Promise<{ token: string; profile: string }> {
  const read = async () => (await rpc<State[]>("azads_get_state", {}))[0] ?? null;
  let s = await read();
  if (!isFresh(s)) {
    await rpc("azads_refresh_token", { p_force: false }).catch(() => null);
    s = await read();
  }
  if (!isFresh(s) || !s!.profile_id) throw new Error("azads_token_indisponivel");
  return { token: s!.access_token!, profile: s!.profile_id! };
}

const adsHeaders = (a: { token: string; profile: string }) => ({
  "Amazon-Advertising-API-ClientId": CLIENT_ID,
  "Amazon-Advertising-API-Scope": a.profile,
  Authorization: `Bearer ${a.token}`,
});

async function pedir(a: { token: string; profile: string }, de: string, ate: string) {
  const criados: string[] = [];
  const erros: string[] = [];
  for (const [product, reportTypeId] of PRODUCTS) {
    const resp = await fetch(`${ADS_API}/reporting/reports`, {
      method: "POST",
      headers: { ...adsHeaders(a), "Content-Type": "application/vnd.createasyncreportrequest.v3+json" },
      body: JSON.stringify({
        name: `hub azads ${product} ${de}..${ate}`,
        startDate: de, endDate: ate,
        configuration: {
          adProduct: product,
          groupBy: ["campaign"],
          columns: ["date", "campaignId", "campaignName", "cost", "impressions", "clicks"],
          reportTypeId, timeUnit: "DAILY", format: "GZIP_JSON",
        },
      }),
    });
    const body = await resp.json().catch(() => null);
    // 425 = relatório idêntico já existe/recente — a Amazon devolve o reportId no detalhe
    const rid = body?.reportId ?? (resp.status === 425 ? body?.detail?.match(/[0-9a-f-]{36}/)?.[0] : null);
    if (rid) {
      await rpc("azads_job_upsert", { p_report_id: rid, p_ad_product: product, p_de: de, p_ate: ate });
      criados.push(`${product}:${rid}`);
    } else {
      erros.push(`${product}: ${resp.status} ${JSON.stringify(body).slice(0, 200)}`);
    }
  }
  return { criados, erros };
}

type Job = { report_id: string; ad_product: string; de: string; ate: string; tentativas: number };

async function colher(a: { token: string; profile: string }) {
  const jobs = await rpc<Job[]>("azads_jobs_abertos", {});
  let colhidos = 0, pendentes = 0, falhas = 0, gasto = 0;
  for (const j of jobs) {
    const st = await fetch(`${ADS_API}/reporting/reports/${j.report_id}`, { headers: adsHeaders(a) });
    const body = await st.json().catch(() => null);
    const status = body?.status;
    if (status === "COMPLETED" && body?.url) {
      const gz = await fetch(body.url);
      const rows = JSON.parse(
        await new Response(gz.body!.pipeThrough(new DecompressionStream("gzip"))).text(),
      ) as Array<Record<string, unknown>>;
      const res = await rpc<{ inseridas: number; gasto_janela: number }>("azads_replace_gastos", {
        p_ad_product: j.ad_product, p_de: j.de, p_ate: j.ate, p_rows: rows,
      });
      await rpc("azads_job_finaliza", {
        p_report_id: j.report_id, p_status: "INGERIDO",
        p_detalhe: `${res.inseridas} linhas, R$ ${res.gasto_janela} na janela`,
      });
      colhidos++; gasto += Number(res.gasto_janela) || 0;
    } else if (status === "FAILED" || st.status === 404) {
      await rpc("azads_job_finaliza", {
        p_report_id: j.report_id, p_status: "FALHOU",
        p_detalhe: `${st.status} ${JSON.stringify(body).slice(0, 300)}`,
      });
      falhas++;
    } else {
      await rpc("azads_job_tentativa", { p_report_id: j.report_id });
      pendentes++;
    }
  }
  return { colhidos, pendentes, falhas, gasto };
}

Deno.serve(async (req) => {
  if (!(await keyIsValid(req.headers.get("x-api-key")))) {
    return json({ error: "nao autorizado" }, 401);
  }
  let params: { modo?: string; de?: string; ate?: string } = {};
  try { params = await req.json(); } catch { /* GET/sem corpo */ }
  const modo = params.modo ?? "colher";

  try {
    const a = await getAuth();
    const out: Record<string, unknown> = { modo };

    if (modo === "colher" || modo === "ciclo") {
      const c = await colher(a);
      out.jobs_colhidos = c.colhidos;
      out.jobs_pendentes = c.pendentes;
      out.jobs_falhos = c.falhas;
      out.gasto_ingerido = Math.round(c.gasto * 100) / 100;
    }
    if (modo === "pedir" || modo === "ciclo") {
      if (!params.de || !params.ate) return json({ error: "faltam de/ate" }, 400);
      const p = await pedir(a, params.de, params.ate);
      out.reports_pedidos = p.criados;
      if (p.erros.length) out.reports_erros = p.erros;
    }
    out.resumo = `colhidos=${out.jobs_colhidos ?? "-"} pendentes=${out.jobs_pendentes ?? "-"} ` +
      `falhos=${out.jobs_falhos ?? "-"} pedidos=${(out.reports_pedidos as string[])?.length ?? "-"} ` +
      `gasto=R$${out.gasto_ingerido ?? 0}`;
    return json(out);
  } catch (err) {
    return json({ error: "ingest_falhou", detalhe: String(err).slice(0, 400) }, 500);
  }
});
