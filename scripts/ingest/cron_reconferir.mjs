// MOTOR do cron — FUNÇÃO 2: reconferir_modificados(janela_dias=30).
// Passe A: order.date_last_updated.from = hoje − janela (os modificados).
// Passe B (CRÍTICO): order.status=cancelled,pending_cancel com o MESMO filtro de
//   last_updated — a doc do ML confirma que a busca de vendedor ESCONDE cancelados.
// Detecta o que mudou (status/reembolso) contra a base e faz UPDATE SÓ da LINHA EXISTENTE
// (não insere pedido novo), atualizando status/valor_reembolsado/data_cancelamento/date_last_updated.
// Atribuição de `data` = date_closed@SP (a venda fica no dia original). GUARDA: descarta
// pedidos cujo date_closed cai HOJE (nunca toca o dia corrente).
// Uso: node scripts/ingest/cron_reconferir.mjs [janela_dias=30]
import { getToken, mgmt, mlGet, spDate, hojeSP, cutoffSP, enc, sleep, montarPedido, upsertPedidos, upsertItens } from "./cron_lib.mjs";

const MAX_OFFSET = 10000; // teto de paginação do /orders/search (offset+limit ≤ 10k)

/** Pagina /orders/search por last_updated (opcionalmente com status). Cap-aware. */
async function buscarModificados(token, sellerId, FROM, statusCsv) {
  const orders = [];
  let offset = 0, total = Infinity, pages = 0, cap = false;
  const st = statusCsv ? `&order.status=${enc(statusCsv)}` : "";
  while (offset < total) {
    if (offset >= MAX_OFFSET) { cap = true; break; }
    const j = await mlGet(token, `/orders/search?seller=${sellerId}&order.date_last_updated.from=${enc(FROM)}${st}&sort=date_desc&offset=${offset}&limit=50`);
    if (j.__err) throw new Error(`orders/search (last_updated${st}) HTTP ${j.__err}`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += 50; pages++;
    if (res.length === 0) break;
    await sleep(110);
  }
  return { orders, total, pages, cap };
}

export async function reconferirModificados(janela, token, sellerId) {
  const hoje = hojeSP();
  const cut = cutoffSP(janela);
  const FROM = `${cut}T00:00:00.000-03:00`;

  const A = await buscarModificados(token, sellerId, FROM, null);        // modificados (esconde cancelados)
  const B = await buscarModificados(token, sellerId, FROM, "cancelled"); // cancelados explícitos ('pending_cancel' é filtro inválido → 400)

  // dedup por id
  const map = new Map();
  for (const o of [...A.orders, ...B.orders]) map.set(String(o.id), o);
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
    passeA: { total: A.total, baixados: A.orders.length, cap: A.cap },
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
    console.log(`[reconferir] passe A (modificados): total=${r.passeA.total} baixados=${r.passeA.baixados}${r.passeA.cap ? " [CAP 10k atingido]" : ""}`);
    console.log(`[reconferir] passe B (cancelled):   total=${r.passeB.total} baixados=${r.passeB.baixados}${r.passeB.cap ? " [CAP 10k atingido]" : ""}`);
    console.log(`[reconferir] distintos=${r.distintos} | descartados(dia corrente)=${r.descartadosHoje} | avaliados=${r.avaliados}`);
    console.log(`[reconferir] fora_da_base(ignorados)=${r.foraDaBase} | existentes=${r.existentes} | mudaram(status/reemb)=${r.mudaram} | UPSERTADOS=${r.upsertados} | cancel_detail fetch=${r.cancelDetail}`);
    console.log(`[reconferir] AMOSTRA (pedido_id | status de→para | reembolso de→para):`);
    for (const a of r.amostra) console.log(`   ${a.pid} | ${a.de} → ${a.para} | ${a.reembDe} → ${a.reembPara}`);
    console.log("[reconferir] OK");
  })().catch((e) => { console.error("ERRO:", e.message); process.exit(1); });
}
