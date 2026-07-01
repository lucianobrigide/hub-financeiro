import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// MOTOR de ingestão da bruta (ml_pedidos) como Edge Function — porta do motor já
// validado em scripts/ingest/cron_*.mjs. Reusa EXATAMENTE o padrão da ml-token:
//   • env SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (auto-injetados)
//   • auth por x-api-key validada no Vault via RPC public.ml_token_check
//   • token OAuth vivo via RPC public.ml_get_state (+ ml_refresh_token se stale)
//   • escrita SÓ via RPCs SECURITY DEFINER (ml_upsert_pedidos / _itens / ml_pedidos_estado)
// NUNCA imprime token nem service_key. PAT/Management API não entram aqui (isso é dev-only).
//
// Modos (POST JSON): { modo: "fechar"|"reconferir"|"ambos" (default ambos),
//   dia: "YYYY-MM-DD" (fechar; default = ontem SP), janela: 30 (reconferir),
//   deadlineMs: 380000 }.
// Guarda do dia corrente: fechar NUNCA processa hoje (fecha só o anterior).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ML_API = "https://api.mercadolibre.com";
const SKEW_MS = 10 * 60 * 1000;
const MAX_OFFSET = 10000; // teto de paginação do /orders/search
const LIMIT = 50;
const H = 3600000;

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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const enc = encodeURIComponent;
const p2 = (n: number, l = 2) => String(n).padStart(l, "0");

// ---- datas em America/Sao_Paulo (UTC−03:00 fixo, sem horário de verão) ----
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

// ---- auth (x-api-key validada no Vault) ----
async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_token_check`, {
    method: "POST", headers: restHeaders, body: JSON.stringify({ p_key: candidate }),
  });
  if (!resp.ok) return false;
  return (await resp.json().catch(() => false)) === true;
}

// ---- token OAuth vivo (mesma lógica get-or-refresh da ml-token) ----
type State = { access_token: string | null; expires_at: string | null; user_id: string | null };
async function readState(): Promise<State | null> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_get_state`, {
    method: "POST", headers: restHeaders, body: "{}",
  });
  if (!resp.ok) return null;
  const rows = await resp.json().catch(() => null);
  return Array.isArray(rows) && rows.length ? (rows[0] as State) : null;
}
const isFresh = (s: State | null) =>
  !!s?.access_token && !!s.expires_at && new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;
async function getToken(): Promise<{ token: string; sellerId: string }> {
  let s = await readState();
  if (!isFresh(s)) {
    await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_refresh_token`, {
      method: "POST", headers: restHeaders, body: JSON.stringify({ p_force: false }),
    });
    s = await readState();
  }
  if (!isFresh(s)) throw new Error("token_indisponivel");
  return { token: s!.access_token!, sellerId: String(s!.user_id) };
}

// ---- helpers de banco (RPCs) ----
async function rpc<T>(fn: string, body: unknown): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST", headers: restHeaders, body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`rpc ${fn} HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r.json();
}

// ---- ML GET com backoff 429 ----
async function mlGet(token: string, path: string): Promise<any> {
  for (let a = 0; a < 6; a++) {
    try {
      const r = await fetch(ML_API + path, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
      if (r.status === 429) { await sleep(1000 * 2 ** a); continue; }
      if (!r.ok) return { __err: r.status };
      return r.json();
    } catch { await sleep(700 * 2 ** a); }
  }
  return { __err: 429 };
}

// ---- mapeia pedido do ML → linhas do banco (idêntico ao cron_lib.mjs) ----
async function montarPedido(o: any, token: string, resolveCancel: boolean) {
  let cancelDate = o.cancel_detail?.date ?? null;
  let fetched = 0;
  if (resolveCancel && !cancelDate && (o.status === "cancelled" || o.status === "pending_cancel")) {
    const det = await mlGet(token, `/orders/${o.id}`);
    if (!det.__err) { cancelDate = det.cancel_detail?.date ?? null; fetched = 1; }
    await sleep(80);
  }
  // arredonda a 2 casas (soma float dá ruído tipo 209.8999… → evita falso-positivo)
  const reemb = Math.round((o.payments ?? []).reduce((s: number, p: any) => s + (Number(p.transaction_amount_refunded) || 0), 0) * 100) / 100;
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
  for (let i = 0; i < rows.length; i += 100) {
    const chunk = rows.slice(i, i + 100);
    if (chunk.length) await rpc("ml_upsert_pedidos", { p_rows: chunk });
  }
}
async function upsertItens(rows: any[]): Promise<void> {
  for (let i = 0; i < rows.length; i += 150) {
    const chunk = rows.slice(i, i + 150);
    if (chunk.length) await rpc("ml_upsert_itens", { p_rows: chunk });
  }
}

type Ctx = { t0: number; deadline: number };
const overBudget = (c: Ctx) => Date.now() - c.t0 > c.deadline;

// ================= FUNÇÃO 1: fechar_dia =================
async function fecharDia(dia: string, token: string, sellerId: string, ctx: Ctx) {
  if (dia >= hojeSP()) {
    return { dia, recusado: true, motivo: "dia corrente/futuro — fecha só o anterior" };
  }
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
  const totalValor = pedRows.reduce((s, r) => s + (Number(r.valor_total) || 0), 0);
  return { dia, recusado: false, buscados: orders.length, doDia: doDia.length, upsertados: pedRows.length, itens: itemRows.length, valorDia: Math.round(totalValor * 100) / 100, cancelDetail, cap, timedOut };
}

// ================= FUNÇÃO 2: reconferir (passe A fatiado/dia + passe B cancelled) =================
async function varrerIntervaloA(token: string, sellerId: string, fromMs: number, toMs: number, orders: any[], st: any, ctx: Ctx) {
  if (overBudget(ctx)) { st.timedOut = true; return; }
  const qs = `seller=${sellerId}&order.date_last_updated.from=${enc(isoSP(fromMs))}&order.date_last_updated.to=${enc(isoSP(toMs))}&sort=date_asc`;
  const j0 = await mlGet(token, `/orders/search?${qs}&offset=0&limit=${LIMIT}`);
  if (j0.__err) throw new Error(`passe A sonda HTTP ${j0.__err}`);
  const total = j0?.paging?.total ?? 0;
  const horas = (toMs - fromMs) / H;
  if (total > MAX_OFFSET && horas > 1.05) {           // subdivide dia→12h→6h→…
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

  // passe A fatiado por dia. diaAlvo != null → só aquele dia (unidade que o pg_cron
  // orquestra; um disparo por dia cabe folgado nos 150s da Edge). null → janela cheia
  // (útil fora da Edge; na Edge estoura o wall-clock além de ~15 dias).
  const dias = diaAlvo ? [diaAlvo] : diasIntervalo(cut, hoje);
  const ordersA: any[] = [];
  const stA: any = { fatias: 0, subdivisoes: 0, usou12h: false, usou6h: false, menorHoras: 24, cap: false, estourou: [], timedOut: false };
  for (const D of dias) {
    if (overBudget(ctx)) { stA.timedOut = true; break; }
    await varrerIntervaloA(token, sellerId, Date.parse(`${D}T00:00:00.000-03:00`), Date.parse(`${D}T23:59:59.999-03:00`), ordersA, stA, ctx);
  }
  const unicosA = new Set(ordersA.map((o) => String(o.id))).size;

  // passe B cancelados explícitos (separado; cabe sob o teto). Mesma fatia de tempo:
  // dia único quando diaAlvo, senão a janela inteira.
  const bFrom = diaAlvo ? `${diaAlvo}T00:00:00.000-03:00` : `${cut}T00:00:00.000-03:00`;
  const bTo = diaAlvo ? `&order.date_last_updated.to=${enc(`${diaAlvo}T23:59:59.999-03:00`)}` : "";
  const B = await paginarRange(token, `seller=${sellerId}&order.date_last_updated.from=${enc(bFrom)}${bTo}&order.status=cancelled&sort=date_desc`, ctx);

  // dedup por id
  const map = new Map<string, any>();
  for (const o of [...ordersA, ...B.orders]) map.set(String(o.id), o);
  const comDC = [...map.values()].filter((o) => o.date_closed);
  const semHoje = comDC.filter((o) => spDate(o.date_closed) !== hoje);
  const descartadosHoje = comDC.length - semHoje.length;

  // estado ATUAL (update-only: só corrige linha existente, nunca insere)
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

  // fase 1: detecta mudança (status/reembolso) — sem chamadas ML
  const mudou: any[] = [], amostra: any[] = [];
  for (const o of existentes) {
    const { ped } = await montarPedido(o, token, false);
    const prev = antes.get(String(o.id))!;
    if (prev.status !== ped.status || prev.vr !== Number(ped.valor_reembolsado)) {
      mudou.push(o);
      if (amostra.length < 8) amostra.push({ pid: String(o.id), de: prev.status, para: ped.status, reembDe: prev.vr, reembPara: ped.valor_reembolsado });
    }
  }

  // fase 2: só o que mudou → resolve cancel_detail + UPSERT (nas linhas existentes)
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
    passeA: { dias: dias.length, fatias: stA.fatias, subdivisoes: stA.subdivisoes, usou12h: stA.usou12h, usou6h: stA.usou6h, menorHoras: stA.menorHoras, unicos: unicosA, cap: stA.cap, estourou: stA.estourou, timedOut: stA.timedOut },
    passeB: { total: B.total, baixados: B.orders.length, cap: B.cap, timedOut: B.timedOut },
    distintos: map.size, descartadosHoje, avaliados: semHoje.length,
    foraDaBase, existentes: existentes.length, mudaram: mudou.length, upsertados: pedRows.length, cancelDetail, amostra,
  };
}

// ================= handler =================
Deno.serve(async (req) => {
  if (!(await keyIsValid(req.headers.get("x-api-key")))) return json({ error: "nao autorizado" }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { /* corpo vazio = defaults */ }

  const modo = body.modo ?? "ambos";
  const janela = Number(body.janela ?? 30);
  const dia = body.dia ?? ontemSP();
  const reconferirDia = body.reconferirDia ?? null; // 1 dia por disparo (o pg_cron orquestra a janela)
  const ctx: Ctx = { t0: Date.now(), deadline: Number(body.deadlineMs ?? 140000) };

  try {
    const { token, sellerId } = await getToken();
    const out: any = { modo, seller: sellerId, hoje: hojeSP() };
    if (modo === "fechar" || modo === "ambos") out.fechar = await fecharDia(dia, token, sellerId, ctx);
    if (modo === "reconferir" || modo === "ambos") out.reconferir = await reconferir(janela, token, sellerId, ctx, reconferirDia);
    out.elapsedMs = Date.now() - ctx.t0;
    return json(out);
  } catch (e) {
    return json({ error: "falha", detalhe: String((e as Error)?.message ?? e) }, 500);
  }
});
