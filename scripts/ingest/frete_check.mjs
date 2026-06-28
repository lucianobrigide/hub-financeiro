// Checagem READ-ONLY de FRETE de 1 pedido/pack contra o painel do ML.
// NÃO escreve nada (nem ml_pedidos nem ml_envios) — só lê a API e imprime a
// decomposição (gross / comprador / vendedor) p/ bater com a linha "Envios".
// O número que o painel mostra costuma ser o PACK_ID (resolve p/ 1 order).
// Token nunca impresso.
//
// Uso:  node scripts/ingest/frete_check.mjs <order_id|pack_id>
import process from "node:process";

const ML_API = "https://api.mercadolibre.com";
const arg = process.argv[2];
if (!arg) { console.error("Uso: node scripts/ingest/frete_check.mjs <order_id|pack_id>"); process.exit(1); }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function getToken() {
  const r = await fetch(process.env.ML_TOKEN_URL, { headers: { "x-api-key": process.env.ML_TOKEN_API_KEY } });
  if (!r.ok) throw new Error(`ml-token HTTP ${r.status}`);
  const b = await r.json(); return { token: b.access_token, sellerId: String(b.user_id) };
}
async function mlGet(token, path, extraHeaders = {}) {
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
const brl = (v) => (v == null ? "—" : `R$ ${Number(v).toFixed(2)}`);

(async () => {
  const { token, sellerId } = await getToken();
  console.log(`Token vivo OK. seller=${sellerId}. Checando ${arg}…\n`);

  // 1) resolve o argumento -> 1 order. Tenta como order; se não, trata como pack.
  let order = await mlGet(token, `/orders/${arg}`);
  if (order.__err) {
    const pack = await mlGet(token, `/packs/${arg}`);
    if (pack.__err) { console.error(`Não é order nem pack válido (order HTTP ${order.__err}).`); process.exit(1); }
    const first = (pack.orders ?? [])[0];
    if (!first) { console.error("Pack sem orders."); process.exit(1); }
    console.log(`${arg} é um PACK com ${pack.orders.length} order(s) -> usando order ${first.id}.`);
    order = await mlGet(token, `/orders/${first.id}`);
    if (order.__err) { console.error(`order HTTP ${order.__err}`); process.exit(1); }
  }

  const shippingId = order.shipping?.id;
  const valorTotal = order.total_amount;
  const saleFee = (order.order_items ?? []).reduce((s, it) => s + (Number(it.sale_fee) || 0) * (Number(it.quantity) || 0), 0);
  console.log(`order ${order.id} | status ${order.status} | total ${brl(valorTotal)} | pack_id ${order.pack_id ?? "—"} | shipping.id ${shippingId ?? "—"}`);
  if (!shippingId) { console.log("Sem shipping.id — venda sem envio associado."); process.exit(0); }

  // 2) custos do envio (x-format-new:true)
  const sh = await mlGet(token, `/shipments/${shippingId}`, { "x-format-new": "true" });
  const costs = await mlGet(token, `/shipments/${shippingId}/costs`, { "x-format-new": "true" });
  if (costs.__err) { console.error(`costs HTTP ${costs.__err}`); process.exit(1); }
  const sender = (costs.senders ?? []).find((s) => String(s.user_id) === sellerId) ?? (costs.senders ?? [])[0] ?? {};

  console.log(`\nshipment ${shippingId} | logistic ${sh.logistic_type ?? "—"} | status ${sh.status ?? "—"}`);
  console.log(`  gross_amount ........ ${brl(costs.gross_amount)}`);
  console.log(`  receiver (comprador)  ${brl(costs.receiver?.cost)}`);
  console.log(`  senders[NOSSO] ...... ${brl(sender.cost)}   <- linha "Envios" do painel`);
  console.log(`\nCross-check líquido: ${brl(valorTotal)} − comissão ${brl(saleFee)} − frete ${brl(sender.cost)} = ${brl(Number(valorTotal) - saleFee - (Number(sender.cost) || 0))}`);
})().catch((e) => { console.error("ERRO:", e.message); process.exit(1); });
