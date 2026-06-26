// Ingestão de UM dia (argv[2] = 'YYYY-MM-DD', America/Sao_Paulo), só bruta/itens
// (+data_cancelamento). Sem passe de claims. Token e PAT nunca impressos.
import fs from "node:fs";
import os from "node:os";

const PROJECT_REF = "klwczmapuupensozxbsr";
const ML_API = "https://api.mercadolibre.com";
const DIA = process.argv[2];
if (!/^\d{4}-\d{2}-\d{2}$/.test(DIA || "")) { console.error("uso: node ingest_param.mjs YYYY-MM-DD"); process.exit(1); }
const [Y, M, D] = DIA.split("-").map(Number);
const NEXT = new Date(Date.UTC(Y, M - 1, D + 1)).toISOString().slice(0, 10); // dia seguinte (rola mês)
const FROM = `${DIA}T00:00:00.000-03:00`;   // SP = UTC-3
const TO   = `${NEXT}T00:00:00.000-03:00`;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const spDate = (iso) => (iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }) : null);
const enc = encodeURIComponent;

const PAT = process.env.SUPABASE_ACCESS_TOKEN ?? JSON.parse(fs.readFileSync(os.homedir() + "/.claude.json", "utf8"))?.mcpServers?.supabase?.env?.SUPABASE_ACCESS_TOKEN;
if (!PAT) { console.error("FALHA: PAT ausente."); process.exit(1); }

async function mgmt(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: "POST", headers: { Authorization: `Bearer ${PAT}`, "Content-Type": "application/json" }, body: JSON.stringify({ query }),
  });
  if (!r.ok) throw new Error(`Management API HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}
async function getToken() {
  const r = await fetch(process.env.ML_TOKEN_URL, { headers: { "x-api-key": process.env.ML_TOKEN_API_KEY } });
  if (!r.ok) throw new Error(`ml-token HTTP ${r.status}`);
  const b = await r.json(); return { token: b.access_token, sellerId: String(b.user_id) };
}
async function mlGet(token, path) {
  for (let a = 0; a < 6; a++) {
    const r = await fetch(ML_API + path, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
    if (r.status === 429) { await sleep(1000 * 2 ** a + Math.floor(Math.random() * 250)); continue; }
    if (!r.ok) return { __err: r.status };
    return r.json();
  }
  return { __err: 429 };
}
const S = (v) => (v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`);
const N = (v) => (v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? "null" : String(Number(v)));
async function batch(rows, sqlFor, chunk = 100) { for (let i = 0; i < rows.length; i += chunk) if (rows.slice(i, i + chunk).length) await mgmt(sqlFor(rows.slice(i, i + chunk))); }

(async () => {
  const { token, sellerId } = await getToken();
  console.log(`Token vivo OK. seller=${sellerId}. Dia alvo SP=${DIA} (janela date_closed [${FROM} .. ${TO}]).`);

  const orders = [];
  let offset = 0, total = Infinity, pages = 0;
  while (offset < total) {
    const j = await mlGet(token, `/orders/search?seller=${sellerId}&order.date_closed.from=${enc(FROM)}&order.date_closed.to=${enc(TO)}&sort=date_asc&offset=${offset}&limit=50`);
    if (j.__err) throw new Error(`orders/search HTTP ${j.__err}`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += 50; pages++;
    if (res.length === 0) break; await sleep(120);
  }
  const doDia = orders.filter((o) => o.date_closed && spDate(o.date_closed) === DIA);
  const vazaram = orders.filter((o) => o.date_closed && spDate(o.date_closed) === NEXT);
  console.log(`Páginas=${pages}, janela total=${total}, baixados=${orders.length}, no dia=${doDia.length}, vazaram p/ ${NEXT}=${vazaram.length}.`);

  let fetchedDetail = 0;
  const pedRows = [], itemRows = [];
  for (const o of doDia) {
    let cancelDate = o.cancel_detail?.date ?? null;
    if (!cancelDate && (o.status === "cancelled" || o.status === "pending_cancel")) {
      const det = await mlGet(token, `/orders/${o.id}`);
      if (!det.__err) { cancelDate = det.cancel_detail?.date ?? null; fetchedDetail++; }
      await sleep(80);
    }
    const reemb = (o.payments ?? []).reduce((s, p) => s + (Number(p.transaction_amount_refunded) || 0), 0);
    const qtd = (o.order_items ?? []).reduce((s, it) => s + (Number(it.quantity) || 0), 0);
    pedRows.push({ id: o.id, data: DIA, dc: o.date_closed, dcr: o.date_created, status: o.status, total: o.total_amount, reemb, qtd, canal: o.context?.channel ?? "mercado_livre", moeda: o.currency_id, dlu: o.date_last_updated ?? o.last_updated, dcancel: spDate(cancelDate) });
    for (const it of o.order_items ?? [])
      itemRows.push({ pid: o.id, item_id: it.item?.id, vid: it.item?.variation_id ?? 0, sku: it.item?.seller_sku ?? it.item?.seller_custom_field ?? null, titulo: it.item?.title, q: it.quantity, vu: it.unit_price, fee: it.sale_fee ?? null, moeda: it.currency_id ?? o.currency_id });
  }

  await batch(pedRows, (p) =>
    `insert into public.ml_pedidos (pedido_id,data,date_closed,date_created,status,valor_total,valor_reembolsado,qtd_unidades,canal,moeda,date_last_updated,data_cancelamento) values ` +
    p.map((r) => `(${N(r.id)},${S(r.data)},${S(r.dc)},${S(r.dcr)},${S(r.status)},${N(r.total)},${N(r.reemb)},${N(r.qtd)},${S(r.canal)},${S(r.moeda)},${S(r.dlu)},${S(r.dcancel)})`).join(",") +
    ` on conflict (pedido_id) do update set data=excluded.data,date_closed=excluded.date_closed,date_created=excluded.date_created,status=excluded.status,valor_total=excluded.valor_total,valor_reembolsado=excluded.valor_reembolsado,qtd_unidades=excluded.qtd_unidades,canal=excluded.canal,moeda=excluded.moeda,date_last_updated=excluded.date_last_updated,data_cancelamento=excluded.data_cancelamento,atualizado_em=now();`);
  await batch(itemRows, (p) =>
    `insert into public.ml_pedido_itens (pedido_id,item_id,variation_id,sku,titulo,quantidade,valor_unitario,sale_fee,moeda) values ` +
    p.map((r) => `(${N(r.pid)},${S(r.item_id)},${N(r.vid)},${S(r.sku)},${S(r.titulo)},${N(r.q)},${N(r.vu)},${N(r.fee)},${S(r.moeda)})`).join(",") +
    ` on conflict (pedido_id,item_id,variation_id) do update set sku=excluded.sku,titulo=excluded.titulo,quantidade=excluded.quantidade,valor_unitario=excluded.valor_unitario,sale_fee=excluded.sale_fee,moeda=excluded.moeda;`, 150);

  console.log(`UPSERT: ${pedRows.length} pedidos, ${itemRows.length} itens (cancel_detail via /orders/$id: ${fetchedDetail}).`);
  console.log(`>> vazaram p/ ${NEXT}: ${vazaram.length}`);
  console.log("CONCLUÍDO.");
})().catch((e) => { console.error("ERRO:", e.message); process.exit(1); });
