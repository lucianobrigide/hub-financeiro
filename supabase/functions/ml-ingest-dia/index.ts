import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// MOTOR de ingestão do Hub como Edge Function. Reusa o padrão da ml-token:
//   • env SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (auto-injetados)
//   • auth por x-api-key validada no Vault via RPC public.ml_token_check
//   • token OAuth vivo via RPC public.ml_get_state (+ ml_refresh_token se stale)
//   • escrita SÓ via RPCs SECURITY DEFINER. PAT/Management API NÃO entram aqui.
// NUNCA imprime token nem service_key.
//
// Modos (POST JSON): { modo, dia, janela, reconferirDia, limite, deadlineMs }
//   fechar      — fecha o dia (bruta+comissão+itens) e grava shipping_id (fase A do frete)
//   reconferir  — reconfere modificados (por dia, via reconferirDia; janela p/ full)
//   ads         — gasto de ADS (product_ads + brand_ads) de UM dia fechado
//   full        — billing Fulfillment (ciclo atual + anterior)
//   afiliados   — billing CVAF (afiliados, ciclo atual + anterior; régua creation_date)
//   difal       — billing CDIFAL (ICMS-DIFAL interestadual, ciclo atual + anterior; régua creation_date)
//   seguidores  — billing CDLIT (Publicidade "Aumentar seguidores", ciclo atual + anterior; régua creation_date; entra na linha ADS)
//   frete       — /shipments/costs dos envios pendentes da janela trailing, em 1 chunk (cursor)
//   ambos       — fechar + reconferir (compat)

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ML_API = "https://api.mercadolibre.com";
const SITE = "MLB";
const SKEW_MS = 10 * 60 * 1000;
const MAX_OFFSET = 10000;
const LIMIT = 50;
const H = 3600000;

const restHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8" } });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const enc = encodeURIComponent;
const p2 = (n: number, l = 2) => String(n).padStart(l, "0");
const r2 = (n: number) => Math.round((Number(n) || 0) * 100) / 100;

// ---- datas em America/Sao_Paulo (UTC−03:00 fixo) ----
const spDate = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }) : null;
const hojeSP = () => new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
function ontemSP(): string {
  const [Y, M, D] = hojeSP().split("-").map(Number);
  return new Date(Date.UTC(Y, M - 1, D - 1)).toISOString().slice(0, 10);
}
function cutoffSP(janela: number): string {
  const [Y, M, D] = hojeSP().split("-").map(Number);
  return new Date(Date.UTC(Y, M - 1, D - janela)).toISOString().slice(0, 10);
}
function mesKey(offsetM: number): string {
  const [Y, M] = hojeSP().split("-").map(Number);
  const d = new Date(Date.UTC(Y, M - 1 + offsetM, 1));
  return `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-01`;
}
function isoSP(ms: number): string {
  const d = new Date(ms - 3 * H);
  return `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())}T${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}:${p2(d.getUTCSeconds())}.${p2(d.getUTCMilliseconds(), 3)}-03:00`;
}
function diasIntervalo(cut: string, hoje: string): string[] {
  const dias: string[] = [];
  let ms = Date.parse(`${cut}T12:00:00.000-03:00`);
  const fim = Date.parse(`${hoje}T12:00:00.000-03:00`);
  while (ms <= fim) {
    const d = new Date(ms - 3 * H);
    dias.push(`${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())}`);
    ms += 24 * H;
  }
  return dias;
}

// ---- auth ----
async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_token_check`, {
    method: "POST", headers: restHeaders, body: JSON.stringify({ p_key: candidate }),
  });
  if (!resp.ok) return false;
  return (await resp.json().catch(() => false)) === true;
}

// ---- token OAuth vivo ----
type State = { access_token: string | null; expires_at: string | null; user_id: string | null };
async function readState(): Promise<State | null> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_get_state`, { method: "POST", headers: restHeaders, body: "{}" });
  if (!resp.ok) return null;
  const rows = await resp.json().catch(() => null);
  return Array.isArray(rows) && rows.length ? (rows[0] as State) : null;
}
const isFresh = (s: State | null) =>
  !!s?.access_token && !!s.expires_at && new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;
async function getToken(): Promise<{ token: string; sellerId: string }> {
  let s = await readState();
  if (!isFresh(s)) {
    await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_refresh_token`, { method: "POST", headers: restHeaders, body: JSON.stringify({ p_force: false }) });
    s = await readState();
  }
  if (!isFresh(s)) throw new Error("token_indisponivel");
  return { token: s!.access_token!, sellerId: String(s!.user_id) };
}

// ---- helpers de banco (RPCs) ----
async function rpc<T>(fn: string, body: unknown): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers: restHeaders, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`rpc ${fn} HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r.json();
}

// ---- ML GET com backoff 429 (extraHeaders p/ Api-Version, x-format-new, etc) ----
async function mlGet(token: string, path: string, extraHeaders: Record<string, string> = {}): Promise<any> {
  for (let a = 0; a < 6; a++) {
    try {
      const r = await fetch(ML_API + path, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json", ...extraHeaders } });
      if (r.status === 429) { await sleep(1000 * 2 ** a); continue; }
      if (!r.ok) return { __err: r.status };
      return r.json();
    } catch { await sleep(700 * 2 ** a); }
  }
  return { __err: 429 };
}

// ---- mapeia pedido do ML → linhas do banco ----
async function montarPedido(o: any, token: string, resolveCancel: boolean) {
  let cancelDate = o.cancel_detail?.date ?? null;
  let fetched = 0;
  if (resolveCancel && !cancelDate && (o.status === "cancelled" || o.status === "pending_cancel")) {
    const det = await mlGet(token, `/orders/${o.id}`);
    if (!det.__err) { cancelDate = det.cancel_detail?.date ?? null; fetched = 1; }
    await sleep(80);
  }
  const reemb = r2((o.payments ?? []).reduce((s: number, p: any) => s + (Number(p.transaction_amount_refunded) || 0), 0));
  const qtd = (o.order_items ?? []).reduce((s: number, it: any) => s + (Number(it.quantity) || 0), 0);
  const ped = {
    pedido_id: o.id, data: spDate(o.date_closed), date_closed: o.date_closed, date_created: o.date_created,
    status: o.status, valor_total: o.total_amount, valor_reembolsado: reemb, qtd_unidades: qtd,
    canal: o.context?.channel ?? "mercado_livre", moeda: o.currency_id,
    date_last_updated: o.date_last_updated ?? o.last_updated, data_cancelamento: spDate(cancelDate),
  };
  const itens = (o.order_items ?? []).map((it: any) => ({
    pedido_id: o.id, item_id: it.item?.id, variation_id: it.item?.variation_id ?? 0,
    sku: it.item?.seller_sku ?? it.item?.seller_custom_field ?? null, titulo: it.item?.title,
    quantidade: it.quantity, valor_unitario: it.unit_price, sale_fee: it.sale_fee ?? null,
    moeda: it.currency_id ?? o.currency_id,
  }));
  return { ped, itens, fetched };
}

async function upsertPedidos(rows: any[]): Promise<void> {
  for (let i = 0; i < rows.length; i += 100) { const c = rows.slice(i, i + 100); if (c.length) await rpc("ml_upsert_pedidos", { p_rows: c }); }
}
async function upsertItens(rows: any[]): Promise<void> {
  for (let i = 0; i < rows.length; i += 150) { const c = rows.slice(i, i + 150); if (c.length) await rpc("ml_upsert_itens", { p_rows: c }); }
}

type Ctx = { t0: number; deadline: number };
const overBudget = (c: Ctx) => Date.now() - c.t0 > c.deadline;

// ================= fechar_dia (+ fase A do frete: grava shipping_id) =================
async function fecharDia(dia: string, token: string, sellerId: string, ctx: Ctx) {
  if (dia >= hojeSP()) return { dia, recusado: true, motivo: "dia corrente/futuro — fecha só o anterior" };
  const from = `${dia}T00:00:00.000-03:00`, to = `${dia}T23:59:59.999-03:00`;
  const orders: any[] = [];
  let offset = 0, total = Infinity, cap = false, timedOut = false;
  while (offset < total) {
    if (offset >= MAX_OFFSET) { cap = true; break; }
    if (overBudget(ctx)) { timedOut = true; break; }
    const j = await mlGet(token, `/orders/search?seller=${sellerId}&order.date_closed.from=${enc(from)}&order.date_closed.to=${enc(to)}&sort=date_asc&offset=${offset}&limit=${LIMIT}`);
    if (j.__err) throw new Error(`fechar_dia orders/search HTTP ${j.__err}`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += LIMIT;
    if (res.length === 0) break;
    await sleep(110);
  }
  const doDia = orders.filter((o) => spDate(o.date_closed) === dia);
  const pedRows: any[] = [], itemRows: any[] = [];
  let cancelDetail = 0;
  for (const o of doDia) {
    const { ped, itens, fetched } = await montarPedido(o, token, true);
    pedRows.push(ped); itemRows.push(...itens); cancelDetail += fetched;
  }
  await upsertPedidos(pedRows);
  await upsertItens(itemRows);
  // fase A do frete: grava shipping_id/pack_id (o /costs vem depois, no passo frete)
  const shipRows = doDia.filter((o) => o.shipping?.id).map((o) => ({ pedido_id: o.id, sid: o.shipping.id, pid: o.pack_id ?? null }));
  if (shipRows.length) await rpc("ml_set_shipping_ids", { p_rows: shipRows });
  const totalValor = pedRows.reduce((s, r) => s + (Number(r.valor_total) || 0), 0);
  return { dia, recusado: false, buscados: orders.length, doDia: doDia.length, upsertados: pedRows.length, itens: itemRows.length, shippingIds: shipRows.length, valorDia: r2(totalValor), cancelDetail, cap, timedOut };
}

// ================= reconferir =================
async function varrerIntervaloA(token: string, sellerId: string, fromMs: number, toMs: number, orders: any[], st: any, ctx: Ctx) {
  if (overBudget(ctx)) { st.timedOut = true; return; }
  const qs = `seller=${sellerId}&order.date_last_updated.from=${enc(isoSP(fromMs))}&order.date_last_updated.to=${enc(isoSP(toMs))}&sort=date_asc`;
  const j0 = await mlGet(token, `/orders/search?${qs}&offset=0&limit=${LIMIT}`);
  if (j0.__err) throw new Error(`passe A sonda HTTP ${j0.__err}`);
  const total = j0?.paging?.total ?? 0;
  const horas = (toMs - fromMs) / H;
  if (total > MAX_OFFSET && horas > 1.05) {
    st.subdivisoes++;
    if (horas <= 12.1) st.usou12h = true;
    if (horas <= 6.1) st.usou6h = true;
    const mid = Math.floor((fromMs + toMs) / 2);
    await varrerIntervaloA(token, sellerId, fromMs, mid, orders, st, ctx);
    await varrerIntervaloA(token, sellerId, mid + 1, toMs, orders, st, ctx);
    return;
  }
  st.fatias++;
  st.menorHoras = Math.min(st.menorHoras, horas);
  if (total > MAX_OFFSET) { st.cap = true; st.estourou.push({ from: isoSP(fromMs), to: isoSP(toMs), total }); }
  orders.push(...(j0?.results ?? []));
  let offset = LIMIT;
  while (offset < total) {
    if (offset >= MAX_OFFSET) break;
    if (overBudget(ctx)) { st.timedOut = true; break; }
    const j = await mlGet(token, `/orders/search?${qs}&offset=${offset}&limit=${LIMIT}`);
    if (j.__err) throw new Error(`passe A folha HTTP ${j.__err}`);
    const res = j?.results ?? [];
    orders.push(...res); offset += LIMIT;
    if (res.length === 0) break;
    await sleep(110);
  }
}
async function paginarRange(token: string, qs: string, ctx: Ctx) {
  const orders: any[] = [];
  let offset = 0, total = Infinity, cap = false, timedOut = false;
  while (offset < total) {
    if (offset >= MAX_OFFSET) { cap = true; break; }
    if (overBudget(ctx)) { timedOut = true; break; }
    const j = await mlGet(token, `/orders/search?${qs}&offset=${offset}&limit=${LIMIT}`);
    if (j.__err) throw new Error(`passe B orders/search HTTP ${j.__err}`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += LIMIT;
    if (res.length === 0) break;
    await sleep(110);
  }
  return { orders, total, cap, timedOut };
}
async function reconferir(janela: number, token: string, sellerId: string, ctx: Ctx, diaAlvo: string | null) {
  const hoje = hojeSP();
  const cut = cutoffSP(janela);
  const dias = diaAlvo ? [diaAlvo] : diasIntervalo(cut, hoje);
  const ordersA: any[] = [];
  const stA: any = { fatias: 0, subdivisoes: 0, usou12h: false, usou6h: false, menorHoras: 24, cap: false, estourou: [], timedOut: false };
  for (const D of dias) {
    if (overBudget(ctx)) { stA.timedOut = true; break; }
    await varrerIntervaloA(token, sellerId, Date.parse(`${D}T00:00:00.000-03:00`), Date.parse(`${D}T23:59:59.999-03:00`), ordersA, stA, ctx);
  }
  const unicosA = new Set(ordersA.map((o) => String(o.id))).size;
  const bFrom = diaAlvo ? `${diaAlvo}T00:00:00.000-03:00` : `${cut}T00:00:00.000-03:00`;
  const bTo = diaAlvo ? `&order.date_last_updated.to=${enc(`${diaAlvo}T23:59:59.999-03:00`)}` : "";
  const B = await paginarRange(token, `seller=${sellerId}&order.date_last_updated.from=${enc(bFrom)}${bTo}&order.status=cancelled&sort=date_desc`, ctx);
  const map = new Map<string, any>();
  for (const o of [...ordersA, ...B.orders]) map.set(String(o.id), o);
  const comDC = [...map.values()].filter((o) => o.date_closed);
  const semHoje = comDC.filter((o) => spDate(o.date_closed) !== hoje);
  const descartadosHoje = comDC.length - semHoje.length;
  const ids = semHoje.map((o) => Number(o.id));
  const antes = new Map<string, { status: string; vr: number }>();
  for (let i = 0; i < ids.length; i += 5000) {
    const chunk = ids.slice(i, i + 5000);
    if (!chunk.length) continue;
    const rows = await rpc<any[]>("ml_pedidos_estado", { p_ids: chunk });
    for (const r of rows) antes.set(String(r.pedido_id), { status: r.status, vr: Number(r.valor_reembolsado) });
  }
  const existentes = semHoje.filter((o) => antes.has(String(o.id)));
  const foraDaBase = semHoje.length - existentes.length;
  const mudou: any[] = [], amostra: any[] = [];
  for (const o of existentes) {
    const { ped } = await montarPedido(o, token, false);
    const prev = antes.get(String(o.id))!;
    if (prev.status !== ped.status || prev.vr !== Number(ped.valor_reembolsado)) {
      mudou.push(o);
      if (amostra.length < 8) amostra.push({ pid: String(o.id), de: prev.status, para: ped.status, reembDe: prev.vr, reembPara: ped.valor_reembolsado });
    }
  }
  const pedRows: any[] = [], itemRows: any[] = [];
  let cancelDetail = 0;
  for (const o of mudou) {
    const { ped, itens, fetched } = await montarPedido(o, token, true);
    pedRows.push(ped); itemRows.push(...itens); cancelDetail += fetched;
  }
  await upsertPedidos(pedRows);
  await upsertItens(itemRows);
  return {
    janela, cut, hoje, diaAlvo,
    passeA: { dias: dias.length, fatias: stA.fatias, subdivisoes: stA.subdivisoes, unicos: unicosA, cap: stA.cap, timedOut: stA.timedOut },
    passeB: { total: B.total, baixados: B.orders.length, cap: B.cap, timedOut: B.timedOut },
    distintos: map.size, descartadosHoje, foraDaBase, existentes: existentes.length, mudaram: mudou.length, upsertados: pedRows.length, cancelDetail, amostra,
  };
}

// ================= ADS (um dia fechado) =================
async function ingestAds(dia: string, token: string) {
  const adv = await mlGet(token, `/advertising/advertisers?product_id=PADS`, { "Api-Version": "1" });
  if (adv.__err) throw new Error(`ads advertisers HTTP ${adv.__err}`);
  const advId = adv?.advertisers?.[0]?.advertiser_id;
  if (!advId) return { dia, erro: "sem advertiser PADS" };
  // product_ads: cost por dia (aggregation DAILY)
  const pj = await mlGet(token, `/advertising/${SITE}/advertisers/${advId}/product_ads/campaigns/search?limit=500&offset=0&date_from=${dia}&date_to=${dia}&metrics=cost&aggregation_type=DAILY`, { "api-version": "2" });
  if (pj.__err) throw new Error(`PADS HTTP ${pj.__err}`);
  let pads = 0; for (const r of (pj.results ?? [])) if (r.date === dia) pads += Number(r.cost) || 0;
  // brand_ads: consumed_budget por dia
  const bj = await mlGet(token, `/advertising/advertisers/${advId}/brand_ads/campaigns/metrics?date_from=${dia}&date_to=${dia}&aggregation_type=daily&strategy=marketplace`);
  if (bj.__err) throw new Error(`BADS HTTP ${bj.__err}`);
  let bads = 0; for (const m of (bj.metrics ?? [])) if (m.date === dia) bads += Number(m.metrics?.consumed_budget) || 0;
  const rows = [{ data: dia, produto: "product_ads", gasto: r2(pads) }, { data: dia, produto: "brand_ads", gasto: r2(bads) }];
  await rpc("ml_upsert_ads", { p_rows: rows });
  return { dia, advertiser: advId, product_ads: r2(pads), brand_ads: r2(bads) };
}

// ================= FULL (ciclo atual + anterior) =================
function mapFull(r: any, KEY: string) {
  const ci = r.charge_info ?? {}, fi = r.fulfillment_info ?? {}, di = r.document_info ?? {};
  const cdt = ci.creation_date_time ?? null;
  return {
    detail_id: ci.detail_id, creation_date: cdt ? cdt.slice(0, 10) : null, creation_date_time: cdt,
    tipo: fi.type ?? null, detail_sub_type: ci.detail_sub_type ?? null, detail_amount: ci.detail_amount ?? null,
    transaction_detail: ci.transaction_detail ?? null, concept_type: ci.concept_type ?? null,
    warehouse_id: fi.warehouse_id ?? null, sku: fi.sku ?? null, item_id: fi.item_id ?? null,
    inventory_id: fi.inventory_id ?? null, quantity: fi.quantity ?? null, amount_per_unit: fi.amount_per_unit ?? null,
    legal_document_number: ci.legal_document_number ?? null, document_id: di.document_id ?? null, periodo_key: KEY,
  };
}
async function ingestFull(token: string, ctx: Ctx) {
  const keys = [mesKey(0), mesKey(-1)];
  let grav = 0;
  for (const KEY of keys) {
    let fromId = 0, page = 0;
    while (page < 40) {
      if (overBudget(ctx)) break;
      const j = await mlGet(token, `/billing/integration/periods/key/${KEY}/group/ML/full/details?document_type=BILL&limit=1000&from_id=${fromId}&sort_by=ID&order_by=ASC`);
      if (j.__err) throw new Error(`full HTTP ${j.__err} (key ${KEY})`);
      const results = j.results ?? [];
      if (!results.length) break;
      const rows = results.map((r: any) => mapFull(r, KEY));
      for (let i = 0; i < rows.length; i += 200) await rpc("ml_upsert_full", { p_rows: rows.slice(i, i + 200) });
      grav += rows.length;
      fromId = j.last_id ?? 0; page++;
      if (!fromId) break;
    }
  }
  return { keys, gravados: grav };
}

// ================= AFILIADOS (CVAF — ciclo atual + anterior) =================
// "Cargo por venta con afiliados" do billing /group/ML/details filtrado por CVAF.
// Régua: creation_date (dia em que o ML lançou a cobrança), NÃO data da venda — as
// cobranças CVAF são criadas em lote, meses depois da venda (sale_date antigo). O
// ciclo de billing ~fecha dia 15, então um mês-calendário vem de 2 faturas: por isso
// pesca mesKey(0) + mesKey(-1) (igual Full). Idempotente por detail_id (sem overlap).
// OBS paginação: usa o detail_id do ÚLTIMO registro como próximo from_id — o campo
// j.last_id do endpoint /details pula à frente e derruba registros no fim da página.
function mapAfiliado(r: any, KEY: string) {
  const ci = r.charge_info ?? {}, si = (r.sales_info ?? [])[0] ?? {}, di = r.document_info ?? {};
  const cdt = ci.creation_date_time ?? null;
  return {
    detail_id: ci.detail_id, creation_date: cdt ? cdt.slice(0, 10) : null, creation_date_time: cdt,
    detail_sub_type: ci.detail_sub_type ?? null, detail_amount: ci.detail_amount ?? null,
    transaction_detail: ci.transaction_detail ?? null,
    order_id: si.order_id ?? null, sale_date_time: si.sale_date_time ?? null,
    legal_document_number: ci.legal_document_number ?? null, document_id: di.document_id ?? null, periodo_key: KEY,
  };
}
async function ingestAfiliados(token: string, ctx: Ctx) {
  const keys = [mesKey(0), mesKey(-1)];
  let grav = 0;
  for (const KEY of keys) {
    let fromId = 0, page = 0;
    // from_id é EXCLUSIVO (páginas somam exato, sem overlap). NÃO parar em página curta:
    // o billing API sob carga devolve páginas <1000 no meio da paginação (trunca o fetch).
    // Para só em página VAZIA (última) ou lastId sem avançar. page<60 é backstop.
    while (page < 60) {
      if (overBudget(ctx)) break;
      const j = await mlGet(token, `/billing/integration/periods/key/${KEY}/group/ML/details?document_type=BILL&detail_sub_types=CVAF&limit=1000&from_id=${fromId}&sort_by=ID&order_by=ASC`);
      if (j.__err) throw new Error(`afiliados HTTP ${j.__err} (key ${KEY})`);
      const results = j.results ?? [];
      if (!results.length) break;
      const rows = results.map((r: any) => mapAfiliado(r, KEY));
      for (let i = 0; i < rows.length; i += 200) await rpc("ml_upsert_afiliados", { p_rows: rows.slice(i, i + 200) });
      grav += rows.length;
      const lastId = results[results.length - 1]?.charge_info?.detail_id ?? null;
      if (!lastId || lastId === fromId) break;
      fromId = lastId; page++;
    }
  }
  return { keys, gravados: grav };
}

// ================= DIFAL (CDIFAL — ciclo atual + anterior) =================
// "Cobrança do diferencial de alíquota interestadual (ICMS-DIFAL)" do billing
// /group/ML/details filtrado por CDIFAL. Imposto de venda interestadual, cobrado na
// fatura do ML (marketplace=SHIPPING). Régua creation_date (dia da cobrança). DIFAL é
// DIÁRIO (per-envio), ciclo ~fecha dia 22 → mês-calendário vem de 2 faturas: pesca
// mesKey(0)+mesKey(-1) (igual Full/Afiliado). Idempotente por detail_id. Mesma paginação
// robusta do afiliado (para só em página vazia; billing devolve <1000 no meio).
function mapDifal(r: any, KEY: string) {
  const ci = r.charge_info ?? {}, si = (r.sales_info ?? [])[0] ?? {}, di = r.document_info ?? {}, mi = r.marketplace_info ?? {};
  const cdt = ci.creation_date_time ?? null;
  return {
    detail_id: ci.detail_id, creation_date: cdt ? cdt.slice(0, 10) : null, creation_date_time: cdt,
    detail_sub_type: ci.detail_sub_type ?? null, detail_amount: ci.detail_amount ?? null,
    transaction_detail: ci.transaction_detail ?? null,
    order_id: si.order_id ?? null, sale_date_time: si.sale_date_time ?? null, marketplace: mi.marketplace ?? null,
    legal_document_number: ci.legal_document_number ?? null, document_id: di.document_id ?? null, periodo_key: KEY,
  };
}
async function ingestDifal(token: string, ctx: Ctx) {
  const keys = [mesKey(0), mesKey(-1)];
  let grav = 0;
  for (const KEY of keys) {
    let fromId = 0, page = 0;
    while (page < 60) {
      if (overBudget(ctx)) break;
      const j = await mlGet(token, `/billing/integration/periods/key/${KEY}/group/ML/details?document_type=BILL&detail_sub_types=CDIFAL&limit=1000&from_id=${fromId}&sort_by=ID&order_by=ASC`);
      if (j.__err) throw new Error(`difal HTTP ${j.__err} (key ${KEY})`);
      const results = j.results ?? [];
      if (!results.length) break;
      const rows = results.map((r: any) => mapDifal(r, KEY));
      for (let i = 0; i < rows.length; i += 200) await rpc("ml_upsert_difal", { p_rows: rows.slice(i, i + 200) });
      grav += rows.length;
      const lastId = results[results.length - 1]?.charge_info?.detail_id ?? null;
      if (!lastId || lastId === fromId) break;
      fromId = lastId; page++;
    }
  }
  return { keys, gravados: grav };
}

// ================= SEGUIDORES (CDLIT — ciclo atual + anterior) =================
// Cobrança da campanha de Publicidade "Aumentar os seguidores da sua página" do
// billing /group/ML/details filtrado por CDLIT. Régua creation_date (dia da cobrança),
// mês-calendário — como afiliados/DIFAL, o mês vem de 2 faturas: pesca mesKey(0)+mesKey(-1).
// DIFERENTE de afiliados/difal (que guardam cada cobrança por detail_id numa tabela
// própria), aqui AGREGAMOS por creation_date (dia) e gravamos em ml_ads_diario com
// produto='seguidores' — assim a linha ADS do card (ml_ads soma product_ads+brand_ads+
// seguidores) absorve o custo, sem tocar nos outros ADS. Idempotente: recomputa o total
// diário do billing (2 faturas) e SUBSTITUI via ml_upsert_ads (on conflict data,produto).
async function ingestSeguidores(token: string, ctx: Ctx) {
  const keys = [mesKey(0), mesKey(-1)];
  const porDia = new Map<string, number>();
  let lidos = 0;
  for (const KEY of keys) {
    let fromId = 0, page = 0;
    while (page < 60) {
      if (overBudget(ctx)) break;
      const j = await mlGet(token, `/billing/integration/periods/key/${KEY}/group/ML/details?document_type=BILL&detail_sub_types=CDLIT&limit=1000&from_id=${fromId}&sort_by=ID&order_by=ASC`);
      if (j.__err) throw new Error(`seguidores HTTP ${j.__err} (key ${KEY})`);
      const results = j.results ?? [];
      if (!results.length) break;
      for (const r of results) {
        const ci = r.charge_info ?? {};
        const cdt = ci.creation_date_time ?? null;
        const dia = cdt ? cdt.slice(0, 10) : null;
        if (!dia) continue;
        porDia.set(dia, (porDia.get(dia) ?? 0) + (Number(ci.detail_amount) || 0));
      }
      lidos += results.length;
      const lastId = results[results.length - 1]?.charge_info?.detail_id ?? null;
      if (!lastId || lastId === fromId) break;
      fromId = lastId; page++;
    }
  }
  const rows = [...porDia.entries()].map(([data, gasto]) => ({ data, produto: "seguidores", gasto: r2(gasto) }));
  for (let i = 0; i < rows.length; i += 200) { const c = rows.slice(i, i + 200); if (c.length) await rpc("ml_upsert_ads", { p_rows: c }); }
  return { keys, lidos, dias: rows.length, total: r2([...porDia.values()].reduce((s, v) => s + v, 0)) };
}

// ================= FRETE (chunk de envios pendentes da janela trailing) =================
function costType(cv: any, cc: any) {
  const a = Number(cv) || 0, b = Number(cc) || 0;
  if (a === 0) return "charged";
  return b > 0 ? "partially_free" : "free";
}
async function ingestFreteChunk(janela: number, limite: number, token: string, sellerId: string, ctx: Ctx) {
  const cut = cutoffSP(janela);
  const ids = await rpc<number[]>("ml_frete_pendentes", { p_from: cut, p_limit: limite });
  const rows: any[] = [];
  let erros = 0;
  for (const sid of ids) {
    if (overBudget(ctx)) break;
    const sh = await mlGet(token, `/shipments/${sid}`, { "x-format-new": "true" });
    if (sh.__err) { erros++; continue; }
    const costs = await mlGet(token, `/shipments/${sid}/costs`, { "x-format-new": "true" });
    if (costs.__err) { erros++; continue; }
    const sender = (costs.senders ?? []).find((s: any) => String(s.user_id) === sellerId) ?? (costs.senders ?? [])[0] ?? {};
    const cv = sender.cost ?? null, cc = costs.receiver?.cost ?? null;
    rows.push({ shipment_id: sid, custo_vendedor: cv, custo_comprador: cc, gross_amount: costs.gross_amount ?? null, logistic_type: sh.logistic_type ?? null, cost_type: costType(cv, cc), status: sh.status ?? null, last_updated: sh.last_updated ?? null });
    await sleep(60);
  }
  if (rows.length) await rpc("ml_upsert_envios", { p_rows: rows });
  // restam=true sinaliza ao orquestrador pra chamar de novo (cursor por "pendentes")
  return { janela, pediu: ids.length, gravados: rows.length, erros, restam: ids.length >= limite };
}

// ================= handler =================
Deno.serve(async (req) => {
  if (!(await keyIsValid(req.headers.get("x-api-key")))) return json({ error: "nao autorizado" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { /* corpo vazio = defaults */ }

  const modo = body.modo ?? "ambos";
  const janela = Number(body.janela ?? 30);
  const dia = body.dia ?? ontemSP();
  const reconferirDia = body.reconferirDia ?? null;
  const limite = Number(body.limite ?? 250);
  const ctx: Ctx = { t0: Date.now(), deadline: Number(body.deadlineMs ?? 140000) };

  try {
    const { token, sellerId } = await getToken();
    const out: any = { modo, seller: sellerId, hoje: hojeSP() };
    if (modo === "fechar" || modo === "ambos") out.fechar = await fecharDia(dia, token, sellerId, ctx);
    if (modo === "reconferir" || modo === "ambos") out.reconferir = await reconferir(janela, token, sellerId, ctx, reconferirDia);
    if (modo === "ads") out.ads = await ingestAds(dia, token);
    if (modo === "full") out.full = await ingestFull(token, ctx);
    if (modo === "afiliados") out.afiliados = await ingestAfiliados(token, ctx);
    if (modo === "difal") out.difal = await ingestDifal(token, ctx);
    if (modo === "seguidores") out.seguidores = await ingestSeguidores(token, ctx);
    if (modo === "frete") out.frete = await ingestFreteChunk(janela, limite, token, sellerId, ctx);
    out.elapsedMs = Date.now() - ctx.t0;
    return json(out);
  } catch (e) {
    return json({ error: "falha", detalhe: String((e as Error)?.message ?? e) }, 500);
  }
});
