// MOTOR do cron — FUNÇÃO 2: reconferir_modificados(janela_dias=30).
// Passe A (FATIADO POR DIA): scan NÃO existe pra /orders (só /items e /questions —
//   doc "Busca de itens", 2025-04-07). Pra furar o teto de 10k do offset, varremos a
//   janela dia a dia: para cada D em [hoje−janela, hoje], order.date_last_updated
//   .from=D 00:00 / .to=D 23:59:59.999, sort=date_asc, paginando offset até esgotar.
//   Salvaguarda: se o total de um dia > 10k, subdivide o intervalo pela metade no tempo
//   (dia→12h→6h→…) até cada bloco ficar < 10k.
// Passe B (CRÍTICO): order.status=cancelled com o MESMO filtro de last_updated — a doc
//   do ML confirma que a busca de vendedor ESCONDE cancelados. Cabe sob o teto (~2.9k),
//   fica SEPARADO e igual ('pending_cancel' é filtro inválido → 400).
// Detecta o que mudou (status/reembolso) contra a base e faz UPDATE SÓ da LINHA EXISTENTE
// (não insere pedido novo), atualizando status/valor_reembolsado/data_cancelamento/date_last_updated.
// Atribuição de `data` = date_closed@SP (a venda fica no dia original). GUARDA: descarta
// pedidos cujo date_closed cai HOJE (nunca toca o dia corrente).
// Uso: node scripts/ingest/cron_reconferir.mjs [janela_dias=30]
import { getToken, mgmt, mlGet, spDate, hojeSP, cutoffSP, enc, sleep, montarPedido, upsertPedidos, upsertItens } from "./cron_lib.mjs";

const MAX_OFFSET = 10000; // teto de paginação do /orders/search (offset+limit ≤ 10k)
const LIMIT = 50;
const H = 3600000; // ms por hora
// America/Sao_Paulo é UTC−03:00 fixo (sem horário de verão desde 2019).
const p2 = (n, l = 2) => String(n).padStart(l, "0");

/** Renderiza um instante (ms UTC) como ISO no fuso −03:00 (formato que o /orders/search aceita). */
function isoSP(ms) {
  const d = new Date(ms - 3 * H); // desloca p/ que getUTC* devolva a hora-parede de SP
  return `${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())}T${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())}:${p2(d.getUTCSeconds())}.${p2(d.getUTCMilliseconds(), 3)}-03:00`;
}
/** Lista de datas YYYY-MM-DD (SP) de `cut` até `hoje`, inclusive. */
function diasIntervalo(cut, hoje) {
  const dias = [];
  let ms = Date.parse(`${cut}T12:00:00.000-03:00`);          // meio-dia evita qualquer borda
  const fim = Date.parse(`${hoje}T12:00:00.000-03:00`);
  while (ms <= fim) {
    const d = new Date(ms - 3 * H);
    dias.push(`${d.getUTCFullYear()}-${p2(d.getUTCMonth() + 1)}-${p2(d.getUTCDate())}`);
    ms += 24 * H;
  }
  return dias;
}

/**
 * Passe A: varre o intervalo [fromMs, toMs] por last_updated, paginando por offset.
 * Se paging.total > MAX_OFFSET e o bloco ainda tem > ~1h, subdivide pela metade e recursa
 * (dia→12h→6h→3h…). Empurra as orders em `orders` e contabiliza em `st`.
 */
async function varrerIntervaloA(token, sellerId, fromMs, toMs, orders, st) {
  const qs = `seller=${sellerId}&order.date_last_updated.from=${enc(isoSP(fromMs))}&order.date_last_updated.to=${enc(isoSP(toMs))}&sort=date_asc`;
  const j0 = await mlGet(token, `/orders/search?${qs}&offset=0&limit=${LIMIT}`); // sonda o total (offset 0)
  if (j0.__err) throw new Error(`orders/search (passe A sonda) HTTP ${j0.__err}`);
  const total = j0?.paging?.total ?? 0;
  const horas = (toMs - fromMs) / H;

  if (total > MAX_OFFSET && horas > 1.05) {                  // subdivide (nunca abaixo de ~1h)
    st.subdivisoes++;
    if (horas <= 12.1) st.usou12h = true;
    if (horas <= 6.1) st.usou6h = true;
    const mid = Math.floor((fromMs + toMs) / 2);
    await varrerIntervaloA(token, sellerId, fromMs, mid, orders, st);
    await varrerIntervaloA(token, sellerId, mid + 1, toMs, orders, st);
    return;
  }

  // folha: pagina esse bloco (reusa a sonda como offset 0)
  st.fatias++;
  st.menorHoras = Math.min(st.menorHoras, horas);
  if (total > MAX_OFFSET) { st.cap = true; st.estourou.push({ from: isoSP(fromMs), to: isoSP(toMs), total }); }
  orders.push(...(j0?.results ?? []));
  let offset = LIMIT;
  while (offset < total) {
    if (offset >= MAX_OFFSET) break;                         // segurança (já sinalizado em st.cap)
    const j = await mlGet(token, `/orders/search?${qs}&offset=${offset}&limit=${LIMIT}`);
    if (j.__err) throw new Error(`orders/search (passe A folha) HTTP ${j.__err}`);
    const res = j?.results ?? [];
    orders.push(...res); offset += LIMIT;
    if (res.length === 0) break;
    await sleep(110);
  }
}

/** Passe B: pagina um range único por offset (usado p/ cancelled, que cabe sob o teto). */
async function paginarRange(token, qs) {
  const orders = [];
  let offset = 0, total = Infinity, cap = false;
  while (offset < total) {
    if (offset >= MAX_OFFSET) { cap = true; break; }
    const j = await mlGet(token, `/orders/search?${qs}&offset=${offset}&limit=${LIMIT}`);
    if (j.__err) throw new Error(`orders/search (passe B) HTTP ${j.__err}`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += LIMIT;
    if (res.length === 0) break;
    await sleep(110);
  }
  return { orders, total, cap };
}

export async function reconferirModificados(janela, token, sellerId) {
  const hoje = hojeSP();
  const cut = cutoffSP(janela);

  // ---- Passe A: fatiado por dia (com subdivisão de salvaguarda) ----
  const dias = diasIntervalo(cut, hoje);
  const ordersA = [];
  const stA = { fatias: 0, subdivisoes: 0, usou12h: false, usou6h: false, menorHoras: 24, cap: false, estourou: [] };
  for (const D of dias) {
    const fromMs = Date.parse(`${D}T00:00:00.000-03:00`);
    const toMs = Date.parse(`${D}T23:59:59.999-03:00`);
    await varrerIntervaloA(token, sellerId, fromMs, toMs, ordersA, stA);
  }
  const unicosA = new Set(ordersA.map((o) => String(o.id))).size;

  // ---- Passe B: cancelados explícitos (SEPARADO, igual) ----
  const FROM = `${cut}T00:00:00.000-03:00`;
  const B = await paginarRange(token, `seller=${sellerId}&order.date_last_updated.from=${enc(FROM)}&order.status=cancelled&sort=date_desc`);

  // dedup por id (A fatiado + B)
  const map = new Map();
  for (const o of [...ordersA, ...B.orders]) map.set(String(o.id), o);
  // GUARDA dia corrente: descarta pedidos cujo date_closed cai HOJE (SP)
  const comDC = [...map.values()].filter((o) => o.date_closed);
  const semHoje = comDC.filter((o) => spDate(o.date_closed) !== hoje);
  const descartadosHoje = comDC.length - semHoje.length;

  // estado ATUAL na base. reconferir NÃO insere pedido novo: só corrige a LINHA EXISTENTE.
  // (Senão canceladas antigas — fora do range que trackeamos — entrariam na base. A
  // ingestão de pedidos novos é do fechar_dia.) Detecta mudança por status/reembolso.
  const ids = semHoje.map((o) => String(o.id));
  const antes = new Map();
  for (let i = 0; i < ids.length; i += 500) {
    const chunk = ids.slice(i, i + 500);
    if (!chunk.length) continue;
    const rows = await mgmt(`select pedido_id::text pid, status, valor_reembolsado::text vr from public.ml_pedidos where pedido_id in (${chunk.join(",")});`);
    for (const r of rows) antes.set(r.pid, r);
  }
  const existentes = semHoje.filter((o) => antes.has(String(o.id)));
  const foraDaBase = semHoje.length - existentes.length; // modificados que NÃO estão na base → ignorados

  // fase 1 (leve, sem resolver cancel): detecta mudança de status/reembolso nas linhas existentes
  const mudou = [], amostra = [];
  for (const o of existentes) {
    const { ped } = await montarPedido(o, token, { resolveCancel: false });
    const prev = antes.get(String(o.id));
    const mudouStatus = prev.status !== ped.status;
    const mudouReemb = Number(prev.vr) !== Number(ped.reemb);
    if (mudouStatus || mudouReemb) {
      mudou.push(o);
      if (amostra.length < 8) amostra.push({ pid: String(o.id), de: prev.status, para: ped.status, reembDe: Number(prev.vr), reembPara: ped.reemb });
    }
  }

  // fase 2 (só o que mudou): re-montar resolvendo cancel_detail.date e UPSERT
  const pedRows = [], itemRows = [];
  let cancelDetail = 0;
  for (const o of mudou) {
    const { ped, itens, fetched } = await montarPedido(o, token, { resolveCancel: true });
    pedRows.push(ped); itemRows.push(...itens); cancelDetail += fetched;
  }
  await upsertPedidos(pedRows);
  await upsertItens(itemRows);

  return {
    janela, cut, hoje,
    passeA: { dias: dias.length, fatias: stA.fatias, subdivisoes: stA.subdivisoes, usou12h: stA.usou12h, usou6h: stA.usou6h, menorHoras: stA.menorHoras, unicos: unicosA, cap: stA.cap, estourou: stA.estourou },
    passeB: { total: B.total, baixados: B.orders.length, cap: B.cap },
    distintos: map.size, descartadosHoje, avaliados: semHoje.length,
    foraDaBase, existentes: existentes.length, mudaram: mudou.length, upsertados: pedRows.length, cancelDetail, amostra,
  };
}

// ---- CLI ----
if (import.meta.url === `file://${process.argv[1]}`) {
  const janela = Number(process.argv[2] ?? 30);
  (async () => {
    const { token, sellerId } = await getToken();
    console.log(`[reconferir] hoje SP=${hojeSP()} | janela=${janela}d | cutoff last_updated.from=${cutoffSP(janela)} | seller=${sellerId}`);
    const r = await reconferirModificados(janela, token, sellerId);
    const a = r.passeA;
    console.log(`[reconferir] passe A (fatiado/dia): dias=${a.dias} | fatias_folha=${a.fatias} | subdivisoes=${a.subdivisoes} (12h=${a.usou12h?"sim":"nao"} 6h=${a.usou6h?"sim":"nao"} menor=${a.menorHoras.toFixed(1)}h) | unicos=${a.unicos} | cap=${a.cap?"SIM ⚠️":"nao"}`);
    if (a.estourou.length) for (const e of a.estourou) console.log(`   ⚠️ BLOCO ESTOUROU 10k: ${e.from} → ${e.to} total=${e.total}`);
    console.log(`[reconferir] passe B (cancelled):   total=${r.passeB.total} baixados=${r.passeB.baixados}${r.passeB.cap ? " [CAP 10k atingido]" : ""}`);
    console.log(`[reconferir] distintos=${r.distintos} | descartados(dia corrente)=${r.descartadosHoje} | avaliados=${r.avaliados}`);
    console.log(`[reconferir] fora_da_base(ignorados)=${r.foraDaBase} | existentes=${r.existentes} | mudaram(status/reemb)=${r.mudaram} | UPSERTADOS=${r.upsertados} | cancel_detail fetch=${r.cancelDetail}`);
    console.log(`[reconferir] AMOSTRA (pedido_id | status de→para | reembolso de→para):`);
    for (const am of r.amostra) console.log(`   ${am.pid} | ${am.de} → ${am.para} | ${am.reembDe} → ${am.reembPara}`);
    console.log("[reconferir] OK");
  })().catch((e) => { console.error("ERRO:", e.message); process.exit(1); });
}
