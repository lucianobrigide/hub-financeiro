// Reprocessa o dia 2026-06-10 (America/Sao_Paulo): pedidos por date_closed,
// agora também data_cancelamento (cancel_detail.date) e passe de devoluções com
// range corrigido. Token e PAT nunca impressos.
import fs from "node:fs";
import os from "node:os";

const PROJECT_REF = "klwczmapuupensozxbsr";
const ML_API = "https://api.mercadolibre.com";
const DIA = "2026-06-10";
const FROM = "2026-06-10T00:00:00.000-03:00";   // p/ orders (filtro date_closed aceita -03:00)
const TO   = "2026-06-11T00:00:00.000-03:00";
const FROM_R = "2026-06-10T00:00:00.000-0300";  // p/ claims range (doc usa offset SEM os dois-pontos)
const TO_R   = "2026-06-11T00:00:00.000-0300";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const spDate = (iso) => (iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }) : null);
const enc = encodeURIComponent;

const PAT = process.env.SUPABASE_ACCESS_TOKEN ?? JSON.parse(fs.readFileSync(os.homedir() + "/.claude.json", "utf8"))
  ?.mcpServers?.supabase?.env?.SUPABASE_ACCESS_TOKEN;
if (!PAT) { console.error("FALHA: PAT ausente."); process.exit(1); }

async function mgmt(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: "POST",
    headers: { Authorization: `Bearer ${PAT}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });
  if (!r.ok) throw new Error(`Management API HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

async function getToken() {
  const url = process.env.ML_TOKEN_URL, key = process.env.ML_TOKEN_API_KEY;
  const r = await fetch(url, { headers: { "x-api-key": key } });
  if (!r.ok) throw new Error(`ml-token HTTP ${r.status}`);
  const b = await r.json();
  return { token: b.access_token, sellerId: String(b.user_id) };
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
async function batch(rows, sqlFor, chunk = 100) {
  for (let i = 0; i < rows.length; i += chunk) if (rows.slice(i, i + chunk).length) await mgmt(sqlFor(rows.slice(i, i + chunk)));
}

(async () => {
  const { token, sellerId } = await getToken();
  console.log(`Token vivo OK. seller=${sellerId}.`);

  // 1) pedidos por date_closed
  const orders = [];
  let offset = 0, total = Infinity, pages = 0;
  while (offset < total) {
    const j = await mlGet(token, `/orders/search?seller=${sellerId}&order.date_closed.from=${enc(FROM)}&order.date_closed.to=${enc(TO)}&sort=date_asc&offset=${offset}&limit=50`);
    if (j.__err) throw new Error(`orders/search HTTP ${j.__err}`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += 50; pages++;
    if (res.length === 0) break;
    await sleep(120);
  }
  const doDia = orders.filter((o) => o.date_closed && spDate(o.date_closed) === DIA);
  console.log(`Janela total=${total}, baixados=${orders.length}, no dia SP=${doDia.length}.`);

  // cancel_detail.date: usar do search; se faltar em pedido cancelado, buscar /orders/$id
  let fetchedDetail = 0;
  const pedRows = [], itemRows = [];
  const ingeridos = new Set();
  for (const o of doDia) {
    ingeridos.add(String(o.id));
    let cancelDate = o.cancel_detail?.date ?? null;
    if (!cancelDate && (o.status === "cancelled" || o.status === "pending_cancel")) {
      const det = await mlGet(token, `/orders/${o.id}`);
      if (!det.__err) { cancelDate = det.cancel_detail?.date ?? null; fetchedDetail++; }
      await sleep(80);
    }
    const reemb = (o.payments ?? []).reduce((s, p) => s + (Number(p.transaction_amount_refunded) || 0), 0);
    const qtd = (o.order_items ?? []).reduce((s, it) => s + (Number(it.quantity) || 0), 0);
    pedRows.push({
      id: o.id, data: DIA, dc: o.date_closed, dcr: o.date_created, status: o.status,
      total: o.total_amount, reemb, qtd, canal: o.context?.channel ?? "mercado_livre",
      moeda: o.currency_id, dlu: o.date_last_updated ?? o.last_updated, dcancel: spDate(cancelDate),
    });
    for (const it of o.order_items ?? [])
      itemRows.push({ pid: o.id, item_id: it.item?.id, vid: it.item?.variation_id ?? 0,
        sku: it.item?.seller_sku ?? it.item?.seller_custom_field ?? null, titulo: it.item?.title,
        q: it.quantity, vu: it.unit_price, fee: it.sale_fee ?? null, moeda: it.currency_id ?? o.currency_id });
  }
  console.log(`cancel_detail buscado via /orders/$id: ${fetchedDetail} pedido(s).`);

  await batch(pedRows, (p) =>
    `insert into public.ml_pedidos (pedido_id,data,date_closed,date_created,status,valor_total,valor_reembolsado,qtd_unidades,canal,moeda,date_last_updated,data_cancelamento) values ` +
    p.map((r) => `(${N(r.id)},${S(r.data)},${S(r.dc)},${S(r.dcr)},${S(r.status)},${N(r.total)},${N(r.reemb)},${N(r.qtd)},${S(r.canal)},${S(r.moeda)},${S(r.dlu)},${S(r.dcancel)})`).join(",") +
    ` on conflict (pedido_id) do update set data=excluded.data,date_closed=excluded.date_closed,date_created=excluded.date_created,status=excluded.status,valor_total=excluded.valor_total,valor_reembolsado=excluded.valor_reembolsado,qtd_unidades=excluded.qtd_unidades,canal=excluded.canal,moeda=excluded.moeda,date_last_updated=excluded.date_last_updated,data_cancelamento=excluded.data_cancelamento,atualizado_em=now();`);

  await batch(itemRows, (p) =>
    `insert into public.ml_pedido_itens (pedido_id,item_id,variation_id,sku,titulo,quantidade,valor_unitario,sale_fee,moeda) values ` +
    p.map((r) => `(${N(r.pid)},${S(r.item_id)},${N(r.vid)},${S(r.sku)},${S(r.titulo)},${N(r.q)},${N(r.vu)},${N(r.fee)},${S(r.moeda)})`).join(",") +
    ` on conflict (pedido_id,item_id,variation_id) do update set sku=excluded.sku,titulo=excluded.titulo,quantidade=excluded.quantidade,valor_unitario=excluded.valor_unitario,sale_fee=excluded.sale_fee,moeda=excluded.moeda;`, 150);
  console.log(`UPSERT: ${pedRows.length} pedidos, ${itemRows.length} itens, cancelados c/ data=${pedRows.filter(r=>r.dcancel).length}.`);

  // 2) devoluções — range corrigido (offset -0300)
  const range = `date_created:after:${FROM_R},before:${TO_R}`;
  const cj = await mlGet(token, `/post-purchase/v1/claims/search?players.user_id=${sellerId}&players.role=respondent&range=${enc(range)}&limit=100&offset=0`);
  if (cj.__err) {
    console.log(`claims/search ainda com erro HTTP ${cj.__err}.`);
  } else {
    const claims = cj?.data ?? [];
    console.log(`claims (date_created no dia): ${claims.length} (paging.total=${cj?.paging?.total ?? 0}).`);
    const devRows = [];
    for (const c of claims) {
      const orderId = c.resource === "order" ? c.resource_id : null;
      let returnId = null, statusMoney = null, qtdDev = null;
      const ret = await mlGet(token, `/post-purchase/v2/claims/${c.id}/returns`);
      if (!ret.__err) { returnId = ret?.id ?? null; statusMoney = ret?.status_money ?? null; qtdDev = ret?.orders?.[0]?.return_quantity ?? null; }
      await sleep(120);
      devRows.push({ claim_id: c.id, order_id: orderId && ingeridos.has(String(orderId)) ? orderId : null,
        return_id: returnId, tipo: c.type, reason_id: c.reason_id, claim_status: c.status,
        resolution_reason: c.resolution?.reason ?? null, status_money: statusMoney, qtd_dev: qtdDev,
        date_created: c.date_created, last_updated: c.last_updated });
    }
    if (devRows.length)
      await batch(devRows, (p) =>
        `insert into public.ml_devolucoes (claim_id,order_id,return_id,tipo,reason_id,claim_status,resolution_reason,status_money,qtd_devolvida,date_created,last_updated) values ` +
        p.map((r) => `(${N(r.claim_id)},${N(r.order_id)},${N(r.return_id)},${S(r.tipo)},${S(r.reason_id)},${S(r.claim_status)},${S(r.resolution_reason)},${S(r.status_money)},${N(r.qtd_dev)},${S(r.date_created)},${S(r.last_updated)})`).join(",") +
        ` on conflict (claim_id) do update set order_id=excluded.order_id,return_id=excluded.return_id,tipo=excluded.tipo,reason_id=excluded.reason_id,claim_status=excluded.claim_status,resolution_reason=excluded.resolution_reason,status_money=excluded.status_money,qtd_devolvida=excluded.qtd_devolvida,last_updated=excluded.last_updated,atualizado_em=now();`);
    console.log(`devoluções gravadas: ${devRows.length}; refunded: ${devRows.filter(r=>r.status_money==="refunded").length}.`);
  }
  console.log("REPROCESSO CONCLUÍDO.");
})().catch((e) => { console.error("ERRO:", e.message); process.exit(1); });
