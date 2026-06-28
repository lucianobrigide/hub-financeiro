// Backfill de FRETE (Módulo 02). Em duas fases, por dia (America/Sao_Paulo):
//   A) captura order.shipping.id e order.pack_id de /orders/search -> UPDATE ml_pedidos
//   B) p/ cada shipping_id ainda NÃO presente em ml_envios:
//      GET /shipments/{id} + GET /shipments/{id}/costs (x-format-new:true) -> UPSERT ml_envios
// custo_vendedor = senders[] do nosso seller (= linha "Envios" do painel). Frete é
// por ENVIO, não por unidade. Idempotente e reiniciável (pula envios já gravados).
// Token e PAT nunca impressos. Não repopula a bruta — só frete e os ids de envio.
//
// Uso:  node scripts/ingest/frete_backfill.mjs [YYYY-MM-DD ...]
//   sem args -> junho 01..30/2026 (processa só os pedidos que existem em ml_pedidos).
import fs from "node:fs";
import os from "node:os";

const PROJECT_REF = "klwczmapuupensozxbsr";
const ML_API = "https://api.mercadolibre.com";
const DEFAULT_DAYS = Array.from({ length: 30 }, (_, i) => `2026-06-${String(i + 1).padStart(2, "0")}`);
const DAYS = process.argv.slice(2).length ? process.argv.slice(2) : DEFAULT_DAYS;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const spDate = (iso) => (iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }) : null);
const enc = encodeURIComponent;
const nextOf = (dia) => { const [Y, M, D] = dia.split("-").map(Number); return new Date(Date.UTC(Y, M - 1, D + 1)).toISOString().slice(0, 10); };

const PAT = process.env.SUPABASE_ACCESS_TOKEN ?? JSON.parse(fs.readFileSync(os.homedir() + "/.claude.json", "utf8"))?.mcpServers?.supabase?.env?.SUPABASE_ACCESS_TOKEN;
if (!PAT) { console.error("FALHA: PAT ausente."); process.exit(1); }

async function mgmt(query) {
  for (let a = 0; a < 5; a++) {
    try {
      const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
        method: "POST", headers: { Authorization: `Bearer ${PAT}`, "Content-Type": "application/json" }, body: JSON.stringify({ query }),
      });
      if (!r.ok) throw new Error(`Management API HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
      return r.json();
    } catch (e) { if (a === 4) throw e; await sleep(800 * 2 ** a + Math.floor(Math.random() * 300)); }
  }
}
async function getToken() {
  const r = await fetch(process.env.ML_TOKEN_URL, { headers: { "x-api-key": process.env.ML_TOKEN_API_KEY } });
  if (!r.ok) throw new Error(`ml-token HTTP ${r.status}`);
  const b = await r.json(); return { token: b.access_token, sellerId: String(b.user_id) };
}
async function mlGet(token, path, extraHeaders = {}) {
  for (let a = 0; a < 7; a++) {
    try {
      const r = await fetch(ML_API + path, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...extraHeaders } });
      if (r.status === 429) { await sleep(1000 * 2 ** a + Math.floor(Math.random() * 300)); continue; }
      if (!r.ok) return { __err: r.status };
      return r.json();
    } catch { await sleep(700 * 2 ** a + Math.floor(Math.random() * 300)); }
  }
  return { __err: 429 };
}
const N = (v) => (v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? "null" : String(Number(v)));
const S = (v) => (v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`);
async function batch(rows, sqlFor, chunk = 100) { for (let i = 0; i < rows.length; i += chunk) if (rows.slice(i, i + chunk).length) await mgmt(sqlFor(rows.slice(i, i + chunk))); }

// cost_type derivado de quem paga: comprador paga 0 = frete grátis (vendedor banca);
// comprador paga parte = parcialmente grátis; vendedor paga 0 = cobrado do comprador.
function costType(custoVendedor, custoComprador) {
  const cv = Number(custoVendedor) || 0, cc = Number(custoComprador) || 0;
  if (cv === 0) return "charged";
  return cc > 0 ? "partially_free" : "free";
}

// FASE A: pagina os pedidos do dia e devolve [{pedido_id, shipping_id, pack_id}]
async function capturarEnvios(token, sellerId, dia) {
  const NEXT = nextOf(dia);
  const FROM = `${dia}T00:00:00.000-03:00`, TO = `${NEXT}T00:00:00.000-03:00`;
  const orders = [];
  let offset = 0, total = Infinity;
  while (offset < total) {
    const j = await mlGet(token, `/orders/search?seller=${sellerId}&order.date_closed.from=${enc(FROM)}&order.date_closed.to=${enc(TO)}&sort=date_asc&offset=${offset}&limit=50`);
    if (j.__err) throw new Error(`orders/search HTTP ${j.__err} (dia ${dia})`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += 50;
    if (res.length === 0) break; await sleep(110);
  }
  return orders
    .filter((o) => o.date_closed && spDate(o.date_closed) === dia)
    .map((o) => ({ pedido_id: o.id, shipping_id: o.shipping?.id ?? null, pack_id: o.pack_id ?? null }));
}

// FASE B: ingere os custos de um shipment em ml_envios
async function ingestShipment(token, sellerId, shippingId) {
  const sh = await mlGet(token, `/shipments/${shippingId}`, { "x-format-new": "true" });
  if (sh.__err) return { __err: `shipment ${sh.__err}` };
  const costs = await mlGet(token, `/shipments/${shippingId}/costs`, { "x-format-new": "true" });
  if (costs.__err) return { __err: `costs ${costs.__err}` };
  const sender = (costs.senders ?? []).find((s) => String(s.user_id) === sellerId) ?? (costs.senders ?? [])[0] ?? {};
  const custoVendedor = sender.cost ?? null;
  const custoComprador = costs.receiver?.cost ?? null;
  return {
    shipment_id: shippingId,
    custo_vendedor: custoVendedor,
    custo_comprador: custoComprador,
    gross_amount: costs.gross_amount ?? null,
    logistic_type: sh.logistic_type ?? null,
    cost_type: costType(custoVendedor, custoComprador),
    status: sh.status ?? null,
    last_updated: sh.last_updated ?? null,
  };
}

async function processDay(token, sellerId, dia) {
  // A) captura e grava os ids de envio nos pedidos do dia
  const caps = await capturarEnvios(token, sellerId, dia);
  const comEnvio = caps.filter((c) => c.shipping_id != null);
  await batch(comEnvio, (p) =>
    `update public.ml_pedidos p set shipping_id = v.sid, pack_id = v.pid from (values ` +
    p.map((r) => `(${N(r.pedido_id)}::bigint,${N(r.shipping_id)}::bigint,${N(r.pack_id)}::bigint)`).join(",") +
    `) as v(pedido_id,sid,pid) where p.pedido_id = v.pedido_id;`, 200);

  // B) só os shipping_id do dia que ainda NÃO estão em ml_envios (idempotente/reiniciável)
  const pend = await mgmt(
    `select distinct p.shipping_id as sid from public.ml_pedidos p
     left join public.ml_envios e on e.shipment_id = p.shipping_id
     where p.data = '${dia}' and p.shipping_id is not null and e.shipment_id is null;`);
  const ids = (pend ?? []).map((r) => r.sid).filter((x) => x != null);

  let gravados = 0, erros = 0;
  for (let i = 0; i < ids.length; i += 1) {
    const env = await ingestShipment(token, sellerId, ids[i]);
    if (env.__err) { erros++; continue; }
    await mgmt(
      `insert into public.ml_envios (shipment_id,custo_vendedor,custo_comprador,gross_amount,logistic_type,cost_type,status,last_updated) values ` +
      `(${N(env.shipment_id)},${N(env.custo_vendedor)},${N(env.custo_comprador)},${N(env.gross_amount)},${S(env.logistic_type)},${S(env.cost_type)},${S(env.status)},${S(env.last_updated)}) ` +
      `on conflict (shipment_id) do update set custo_vendedor=excluded.custo_vendedor,custo_comprador=excluded.custo_comprador,gross_amount=excluded.gross_amount,logistic_type=excluded.logistic_type,cost_type=excluded.cost_type,status=excluded.status,last_updated=excluded.last_updated,atualizado_em=now();`);
    gravados++;
    if (i % 50 === 49) await sleep(80);
  }
  return { pedidos: comEnvio.length, enviosNovos: ids.length, gravados, erros };
}

(async () => {
  let { token, sellerId } = await getToken();
  console.log(`Token vivo OK. seller=${sellerId}. Backfill FRETE ${DAYS[0]}..${DAYS[DAYS.length - 1]}.`);
  const falhas = [];
  for (const dia of DAYS) {
    try {
      // renova o token a cada dia (envios fazem muitas chamadas)
      ({ token } = await getToken());
      const r = await processDay(token, sellerId, dia);
      console.log(`dia ${dia}: ${r.pedidos} pedidos c/ envio | ${r.enviosNovos} envios novos | ${r.gravados} gravados | ${r.erros} erros.`);
    } catch (e) {
      console.log(`dia ${dia}: ERRO -> ${e.message} (segue; reprocessável)`);
      falhas.push(dia);
    }
    await sleep(150);
  }
  console.log(falhas.length ? `FALHAS: ${falhas.join(", ")}` : "TODOS OS DIAS OK.");
  console.log("BACKFILL DE FRETE CONCLUÍDO.");
})().catch((e) => { console.error("ERRO FATAL:", e.message); process.exit(1); });
