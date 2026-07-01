// Lib compartilhada do MOTOR do cron (Passo ①). Reusa a lógica do ingest_param.mjs:
// token via ml-token, escrita via Management API (PAT), UPSERT idempotente por pedido_id.
// Token e PAT nunca impressos. NÃO agenda nada — só as funções + helpers.
import fs from "node:fs";
import os from "node:os";

export const ML_API = "https://api.mercadolibre.com";
const PROJECT_REF = "klwczmapuupensozxbsr";

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const enc = encodeURIComponent;
/** Data (YYYY-MM-DD) de um ISO no fuso America/Sao_Paulo. */
export const spDate = (iso) => (iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }) : null);
/** Hoje (YYYY-MM-DD) em America/Sao_Paulo. */
export const hojeSP = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
/** cutoff = hoje − janelaDias (YYYY-MM-DD), em SP. */
export function cutoffSP(janelaDias) {
  const [Y, M, D] = hojeSP().split("-").map(Number);
  return new Date(Date.UTC(Y, M - 1, D - janelaDias)).toISOString().slice(0, 10);
}

const S = (v) => (v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`);
const Nn = (v) => (v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? "null" : String(Number(v)));

const PAT =
  process.env.SUPABASE_ACCESS_TOKEN ??
  (() => { try { return JSON.parse(fs.readFileSync(os.homedir() + "/.claude.json", "utf8"))?.mcpServers?.supabase?.env?.SUPABASE_ACCESS_TOKEN; } catch { return undefined; } })();
if (!PAT) { console.error("FALHA: PAT ausente (SUPABASE_ACCESS_TOKEN ou ~/.claude.json)."); process.exit(1); }

/** Executa SQL via Management API do Supabase (PAT). Retorna o array de linhas. */
export async function mgmt(query) {
  for (let a = 0; a < 4; a++) {
    try {
      const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
        method: "POST", headers: { Authorization: `Bearer ${PAT}`, "Content-Type": "application/json" }, body: JSON.stringify({ query }),
      });
      if (!r.ok) throw new Error(`Management API HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
      return r.json();
    } catch (e) { if (a === 3) throw e; await sleep(700 * 2 ** a); }
  }
}

/** Token vivo do ML via Edge Function ml-token (nunca impresso). */
export async function getToken() {
  const r = await fetch(process.env.ML_TOKEN_URL, { headers: { "x-api-key": process.env.ML_TOKEN_API_KEY } });
  if (!r.ok) throw new Error(`ml-token HTTP ${r.status}`);
  const b = await r.json();
  return { token: b.access_token, sellerId: String(b.user_id) };
}

export async function mlGet(token, path) {
  for (let a = 0; a < 6; a++) {
    try {
      const r = await fetch(ML_API + path, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
      if (r.status === 429) { await sleep(1000 * 2 ** a + Math.floor(Math.random() * 250)); continue; }
      if (!r.ok) return { __err: r.status };
      return r.json();
    } catch { await sleep(700 * 2 ** a); }
  }
  return { __err: 429 };
}

async function batch(rows, sqlFor, chunk = 100) {
  for (let i = 0; i < rows.length; i += chunk) if (rows.slice(i, i + chunk).length) await mgmt(sqlFor(rows.slice(i, i + chunk)));
}

/**
 * Mapeia um pedido do ML → {ped, itens}. `data` = date_closed@SP (atribuição estável:
 * a venda fica no dia do fechamento, mesmo quando o pedido é reconferido depois).
 * resolveCancel=true busca /orders/$id p/ cancelados sem cancel_detail.date (custa 1 call/pedido).
 */
export async function montarPedido(o, token, { resolveCancel = true } = {}) {
  let cancelDate = o.cancel_detail?.date ?? null;
  let fetched = 0;
  if (resolveCancel && !cancelDate && (o.status === "cancelled" || o.status === "pending_cancel")) {
    const det = await mlGet(token, `/orders/${o.id}`);
    if (!det.__err) { cancelDate = det.cancel_detail?.date ?? null; fetched = 1; }
    await sleep(80);
  }
  // arredonda a 2 casas (a soma em float dá ruído tipo 209.8999… → 209.90; evita
  // falso-positivo na detecção de mudança e casa com numeric(14,2) do banco)
  const reemb = Math.round((o.payments ?? []).reduce((s, p) => s + (Number(p.transaction_amount_refunded) || 0), 0) * 100) / 100;
  const qtd = (o.order_items ?? []).reduce((s, it) => s + (Number(it.quantity) || 0), 0);
  const ped = {
    id: o.id, data: spDate(o.date_closed), dc: o.date_closed, dcr: o.date_created, status: o.status,
    total: o.total_amount, reemb, qtd, canal: o.context?.channel ?? "mercado_livre",
    moeda: o.currency_id, dlu: o.date_last_updated ?? o.last_updated, dcancel: spDate(cancelDate),
  };
  const itens = (o.order_items ?? []).map((it) => ({
    pid: o.id, item_id: it.item?.id, vid: it.item?.variation_id ?? 0,
    sku: it.item?.seller_sku ?? it.item?.seller_custom_field ?? null, titulo: it.item?.title,
    q: it.quantity, vu: it.unit_price, fee: it.sale_fee ?? null, moeda: it.currency_id ?? o.currency_id,
  }));
  return { ped, itens, fetched };
}

export async function upsertPedidos(pedRows) {
  if (!pedRows.length) return;
  await batch(pedRows, (p) =>
    `insert into public.ml_pedidos (pedido_id,data,date_closed,date_created,status,valor_total,valor_reembolsado,qtd_unidades,canal,moeda,date_last_updated,data_cancelamento) values ` +
    p.map((r) => `(${Nn(r.id)},${S(r.data)},${S(r.dc)},${S(r.dcr)},${S(r.status)},${Nn(r.total)},${Nn(r.reemb)},${Nn(r.qtd)},${S(r.canal)},${S(r.moeda)},${S(r.dlu)},${S(r.dcancel)})`).join(",") +
    ` on conflict (pedido_id) do update set data=excluded.data,date_closed=excluded.date_closed,date_created=excluded.date_created,status=excluded.status,valor_total=excluded.valor_total,valor_reembolsado=excluded.valor_reembolsado,qtd_unidades=excluded.qtd_unidades,canal=excluded.canal,moeda=excluded.moeda,date_last_updated=excluded.date_last_updated,data_cancelamento=excluded.data_cancelamento,atualizado_em=now();`);
}

export async function upsertItens(itemRows) {
  if (!itemRows.length) return;
  await batch(itemRows, (p) =>
    `insert into public.ml_pedido_itens (pedido_id,item_id,variation_id,sku,titulo,quantidade,valor_unitario,sale_fee,moeda) values ` +
    p.map((r) => `(${Nn(r.pid)},${S(r.item_id)},${Nn(r.vid)},${S(r.sku)},${S(r.titulo)},${Nn(r.q)},${Nn(r.vu)},${Nn(r.fee)},${S(r.moeda)})`).join(",") +
    ` on conflict (pedido_id,item_id,variation_id) do update set sku=excluded.sku,titulo=excluded.titulo,quantidade=excluded.quantidade,valor_unitario=excluded.valor_unitario,sale_fee=excluded.sale_fee,moeda=excluded.moeda;`, 150);
}
