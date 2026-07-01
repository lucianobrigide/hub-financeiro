// MOTOR do cron — FUNÇÃO 1: fechar_dia(data_alvo).
// Fecha UM dia por order.date_closed (mesma lógica do ingest_param.mjs), UPSERT
// idempotente por pedido_id. GUARDA: recusa o dia corrente ou futuro (SP).
// Uso: node scripts/ingest/cron_fechar_dia.mjs YYYY-MM-DD
import { getToken, mlGet, spDate, hojeSP, enc, sleep, montarPedido, upsertPedidos, upsertItens } from "./cron_lib.mjs";

/** Fecha um dia (YYYY-MM-DD, SP) por date_closed. Retorna estatísticas. */
export async function fecharDia(dia, token, sellerId) {
  const hoje = hojeSP();
  if (dia >= hoje) throw new Error(`fechar_dia RECUSADO: alvo ${dia} é o dia corrente/futuro (hoje SP=${hoje}). Fecha só dias anteriores.`);

  const [Y, M, D] = dia.split("-").map(Number);
  const NEXT = new Date(Date.UTC(Y, M - 1, D + 1)).toISOString().slice(0, 10);
  const FROM = `${dia}T00:00:00.000-03:00`, TO = `${NEXT}T00:00:00.000-03:00`;

  const orders = [];
  let offset = 0, total = Infinity, pages = 0;
  while (offset < total) {
    const j = await mlGet(token, `/orders/search?seller=${sellerId}&order.date_closed.from=${enc(FROM)}&order.date_closed.to=${enc(TO)}&sort=date_asc&offset=${offset}&limit=50`);
    if (j.__err) throw new Error(`orders/search HTTP ${j.__err} (dia ${dia})`);
    total = j?.paging?.total ?? 0;
    const res = j?.results ?? [];
    orders.push(...res); offset += 50; pages++;
    if (res.length === 0) break;
    await sleep(120);
  }
  // corte de fuso fino: só os que fecham NO dia alvo (descarta os que "vazam" p/ o dia seguinte)
  const doDia = orders.filter((o) => o.date_closed && spDate(o.date_closed) === dia);
  const vazaram = orders.filter((o) => o.date_closed && spDate(o.date_closed) === NEXT).length;

  const pedRows = [], itemRows = [];
  let cancelDetail = 0;
  for (const o of doDia) {
    const { ped, itens, fetched } = await montarPedido(o, token);
    pedRows.push(ped); itemRows.push(...itens); cancelDetail += fetched;
  }
  await upsertPedidos(pedRows);
  await upsertItens(itemRows);
  return { dia, pages, baixados: orders.length, noDia: doDia.length, vazaram, itens: itemRows.length, cancelDetail };
}

// ---- CLI ----
if (import.meta.url === `file://${process.argv[1]}`) {
  const dia = process.argv[2];
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dia || "")) { console.error("uso: node cron_fechar_dia.mjs YYYY-MM-DD"); process.exit(1); }
  (async () => {
    const { token, sellerId } = await getToken();
    console.log(`[fechar_dia] hoje SP=${hojeSP()} | alvo=${dia} | seller=${sellerId}`);
    const r = await fecharDia(dia, token, sellerId);
    console.log(`[fechar_dia] páginas=${r.pages} baixados=${r.baixados} no_dia=${r.noDia} vazaram=${r.vazaram} itens=${r.itens} cancel_detail=${r.cancelDetail}`);
    console.log("[fechar_dia] OK");
  })().catch((e) => { console.error("ERRO:", e.message); process.exit(1); });
}
