import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Ingestão de pedidos Amazon SP-API (Orders v0). Modos:
//   fechar    — fecha pedidos de UM dia + estima comissão + estima frete
//   confirmar — confirma comissões e frete pendentes via Finances API
//   backfill  — ingere todos os pedidos de um intervalo
// Auth: x-api-key (az_token_key no Vault). Token OAuth via az_get_state/az_refresh_token.
// Volume baixo (~0-2 pedidos/dia), rate limit tranquilo.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SP_API = "https://sellingpartnerapi-na.amazon.com";
const MARKETPLACE_BR = "A2Q3Y263D00KWC";
const SKEW_MS = 10 * 60 * 1000;

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

// ---- auth x-api-key ----
async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/az_token_check`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_key: candidate }),
  });
  if (!resp.ok) return false;
  return (await resp.json().catch(() => false)) === true;
}

// ---- token Amazon LWA ----
type State = { access_token: string | null; expires_at: string | null };

async function readState(): Promise<State | null> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/az_get_state`, {
    method: "POST",
    headers: restHeaders,
    body: "{}",
  });
  if (!resp.ok) return null;
  const rows = await resp.json().catch(() => null);
  return Array.isArray(rows) && rows.length ? (rows[0] as State) : null;
}

const isFresh = (s: State | null) =>
  !!s?.access_token &&
  !!s.expires_at &&
  new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;

async function getToken(): Promise<string> {
  let s = await readState();
  if (!isFresh(s)) {
    await fetch(`${SUPABASE_URL}/rest/v1/rpc/az_refresh_token`, {
      method: "POST",
      headers: restHeaders,
      body: JSON.stringify({ p_force: false }),
    });
    s = await readState();
  }
  if (!isFresh(s)) throw new Error("az_token_indisponivel");
  return s!.access_token!;
}

// ---- RPC helper ----
async function rpc<T>(fn: string, body: unknown): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify(body),
  });
  if (!r.ok)
    throw new Error(`rpc ${fn} HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return r.json();
}

// ---- SP-API GET com retry 429 ----
async function spGet(token: string, path: string): Promise<any> {
  for (let a = 0; a < 5; a++) {
    try {
      const r = await fetch(SP_API + path, {
        headers: { "x-amz-access-token": token, Accept: "application/json" },
      });
      if (r.status === 429) {
        await sleep(2000 * 2 ** a);
        continue;
      }
      if (!r.ok) return { __err: r.status, __msg: (await r.text()).slice(0, 300) };
      return r.json();
    } catch {
      await sleep(1000 * 2 ** a);
    }
  }
  return { __err: 429, __msg: "max_retries" };
}

// ---- SP-API POST com retry 429 ----
async function spPost(token: string, path: string, body: unknown): Promise<any> {
  for (let a = 0; a < 5; a++) {
    try {
      const r = await fetch(SP_API + path, {
        method: "POST",
        headers: {
          "x-amz-access-token": token,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        body: JSON.stringify(body),
      });
      if (r.status === 429) {
        await sleep(2000 * 2 ** a);
        continue;
      }
      if (!r.ok) return { __err: r.status, __msg: (await r.text()).slice(0, 300) };
      return r.json();
    } catch {
      await sleep(1000 * 2 ** a);
    }
  }
  return { __err: 429, __msg: "max_retries" };
}

// ---- Estimar comissão via getMyFeesEstimate + coletar itens ----
async function estimateCommission(
  token: string,
  rows: any[],
): Promise<{ comRows: any[]; itemRows: any[] }> {
  const valid = rows.filter(
    (r) =>
      !["Canceled", "Pending", "Unfulfillable"].includes(r.status) &&
      r.total,
  );
  const comRows: any[] = [];
  const itemRows: any[] = [];
  for (const row of valid) {
    const items = await spGet(
      token,
      `/orders/v0/orders/${row.amazon_order_id}/orderItems`,
    );
    const orderItems = items?.payload?.OrderItems ?? [];
    const asin = orderItems[0]?.ASIN;

    for (const oi of orderItems) {
      if (oi.SellerSKU) {
        itemRows.push({
          amazon_order_id: row.amazon_order_id,
          seller_sku: oi.SellerSKU,
          asin: oi.ASIN,
          quantidade: oi.QuantityOrdered ?? 1,
          preco_unitario: oi.ItemPrice?.Amount
            ? Number(oi.ItemPrice.Amount) / (oi.QuantityOrdered || 1)
            : null,
        });
      }
    }

    let estimated = Math.round(Number(row.total) * 0.12 * 100) / 100;
    if (asin) {
      const fees = await spPost(
        token,
        `/products/fees/v0/items/${asin}/feesEstimate`,
        {
          FeesEstimateRequest: {
            MarketplaceId: MARKETPLACE_BR,
            IsAmazonFulfilled: false,
            PriceToEstimateFees: {
              ListingPrice: {
                CurrencyCode: "BRL",
                Amount: Number(row.total),
              },
            },
            Identifier: row.amazon_order_id,
          },
        },
      );
      const amt =
        fees?.payload?.FeesEstimateResult?.FeesEstimate?.TotalFeesEstimate
          ?.Amount;
      if (amt) estimated = amt;
    }
    comRows.push({
      amazon_order_id: row.amazon_order_id,
      comissao_estimada: estimated,
      confirmado: false,
      fonte: "estimate",
    });
    await sleep(1500);
  }
  return { comRows, itemRows };
}

// ---- Confirmar comissão + frete via Finances API (uma chamada por pedido) ----
async function confirmAll(token: string): Promise<{
  confirmados: number;
  frete_confirmados: number;
  pendentes: number;
}> {
  const pendingCom = await rpc<any[]>("az_pendentes_comissao", {});
  const pendingFrete = await rpc<any[]>("az_pendentes_frete", {});

  const orderMap = new Map<string, any>();
  for (const o of (Array.isArray(pendingCom) ? pendingCom : [])) {
    orderMap.set(o.amazon_order_id, { ...o, need_com: true, need_frete: false });
  }
  for (const o of (Array.isArray(pendingFrete) ? pendingFrete : [])) {
    const ex = orderMap.get(o.amazon_order_id);
    if (ex) {
      ex.need_frete = true;
      ex.frete_estimado = o.frete_estimado;
    } else {
      orderMap.set(o.amazon_order_id, { ...o, need_com: false, need_frete: true });
    }
  }

  const orders = Array.from(orderMap.values());
  if (orders.length === 0) return { confirmados: 0, frete_confirmados: 0, pendentes: 0 };

  const comRows: any[] = [];
  const freteRows: any[] = [];

  for (const o of orders) {
    const data = await spGet(
      token,
      `/finances/v0/orders/${o.amazon_order_id}/financialEvents`,
    );
    if (data?.__err) {
      await sleep(2000);
      continue;
    }

    if (o.need_com) {
      const shipments =
        data?.payload?.FinancialEvents?.ShipmentEventList ?? [];
      let totalFees = 0;
      let found = false;
      for (const s of shipments) {
        for (const item of s.ShipmentItemList ?? []) {
          for (const fee of item.ItemFeeList ?? []) {
            if (
              fee.FeeType === "Commission" ||
              fee.FeeType === "AmazonForAllFee"
            ) {
              totalFees += Math.abs(fee.FeeAmount?.CurrencyAmount ?? 0);
              found = true;
            }
          }
        }
      }
      if (found) {
        comRows.push({
          amazon_order_id: o.amazon_order_id,
          comissao_estimada: o.comissao_estimada,
          comissao_real: Math.round(totalFees * 100) / 100,
          confirmado: true,
          fonte: "finances",
        });
      }
    }

    if (o.need_frete) {
      const services =
        data?.payload?.FinancialEvents?.ServiceFeeEventList ?? [];
      let freteTotal = 0;
      let freteFound = false;
      for (const svc of services) {
        for (const fee of svc.FeeList ?? []) {
          if (fee.FeeType === "MFNPostageFee") {
            freteTotal += Math.abs(fee.FeeAmount?.CurrencyAmount ?? 0);
            freteFound = true;
          }
        }
      }
      if (freteFound) {
        freteRows.push({
          amazon_order_id: o.amazon_order_id,
          frete_estimado: o.frete_estimado ?? 27.95,
          frete_real: Math.round(freteTotal * 100) / 100,
          confirmado: true,
          fonte: "finances",
        });
      }
    }

    await sleep(2000);
  }

  if (comRows.length > 0) await rpc<number>("az_upsert_comissao", { p_rows: comRows });
  if (freteRows.length > 0) await rpc<number>("az_upsert_frete", { p_rows: freteRows });

  return {
    confirmados: comRows.length,
    frete_confirmados: freteRows.length,
    pendentes: orders.length - Math.max(comRows.length, freteRows.length),
  };
}

// ---- busca pedidos por intervalo ----
async function fetchOrders(
  token: string,
  from: string,
  to: string,
): Promise<{ orders: any[]; error?: string }> {
  const orders: any[] = [];
  let nextToken: string | null = null;
  let guard = 0;

  while (guard < 20) {
    guard++;
    let path: string;
    if (nextToken) {
      path = `/orders/v0/orders?NextToken=${enc(nextToken)}&MarketplaceIds=${MARKETPLACE_BR}`;
    } else {
      path = `/orders/v0/orders?MarketplaceIds=${MARKETPLACE_BR}&CreatedAfter=${enc(from)}&CreatedBefore=${enc(to)}`;
    }
    const data = await spGet(token, path);
    if (data.__err)
      return { orders, error: `SP-API ${data.__err}: ${data.__msg}` };

    const payload = data.payload ?? data;
    const batch = payload.Orders ?? payload.orders ?? [];
    orders.push(...batch);

    nextToken = payload.NextToken ?? null;
    if (!nextToken || batch.length === 0) break;
    await sleep(1500);
  }

  return { orders };
}

// ---- datas BRT ----
const hojeSP = () =>
  new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });

function spDate(iso: string | null | undefined): string | null {
  if (!iso) return null;
  return new Date(iso).toLocaleDateString("en-CA", {
    timeZone: "America/Sao_Paulo",
  });
}

function countStatuses(rows: any[]): Record<string, number> {
  const c: Record<string, number> = {};
  for (const r of rows) c[r.status] = (c[r.status] || 0) + 1;
  return c;
}

function mapOrders(orders: any[]) {
  return orders.map((o: any) => ({
    amazon_order_id: o.AmazonOrderId,
    purchase_date: spDate(o.PurchaseDate),
    status: o.OrderStatus,
    total: o.OrderTotal ? Number(o.OrderTotal.Amount) : null,
    currency: o.OrderTotal?.CurrencyCode ?? "BRL",
    num_items:
      (o.NumberOfItemsShipped ?? 0) + (o.NumberOfItemsUnshipped ?? 0),
  }));
}

function sumBruta(rows: any[]): number {
  return rows
    .filter(
      (r: any) => !["Canceled", "Pending", "Unfulfillable"].includes(r.status),
    )
    .reduce((s: number, r: any) => s + (Number(r.total) || 0), 0);
}

// ===================== MAIN =====================
Deno.serve(async (req) => {
  if (!(await keyIsValid(req.headers.get("x-api-key")))) {
    return json({ error: "nao autorizado" }, 401);
  }

  let body: any = {};
  try {
    body = await req.json();
  } catch {}

  const modo = body.modo ?? "fechar";

  let token: string;
  try {
    token = await getToken();
  } catch (e) {
    return json({ error: (e as Error).message }, 502);
  }

  if (modo === "fechar") {
    const dia =
      body.dia ??
      (() => {
        const [Y, M, D] = hojeSP().split("-").map(Number);
        return new Date(Date.UTC(Y, M - 1, D - 1)).toISOString().slice(0, 10);
      })();

    if (dia >= hojeSP()) {
      return json({
        error: "dia corrente/futuro — fecha só o anterior",
        dia,
      });
    }

    const from = `${dia}T00:00:00-03:00`;
    const to = `${dia}T23:59:59.999-03:00`;

    const { orders, error } = await fetchOrders(token, from, to);
    if (error) return json({ error, dia, parcial: orders.length }, 502);

    const rows = mapOrders(orders);
    let upserted = 0;
    if (rows.length > 0) {
      upserted = await rpc<number>("az_upsert_pedidos", { p_rows: rows });
    }

    let comissao_estimadas = 0;
    let frete_estimados = 0;
    let itens_gravados = 0;
    if (rows.length > 0) {
      const { comRows, itemRows } = await estimateCommission(token, rows);
      if (comRows.length > 0) {
        await rpc<number>("az_upsert_comissao", { p_rows: comRows });
        comissao_estimadas = comRows.length;
      }
      if (itemRows.length > 0) {
        await rpc<number>("az_upsert_itens", { p_rows: itemRows });
        itens_gravados = itemRows.length;
      }
      const freteRows = rows
        .filter(
          (r) =>
            !["Canceled", "Pending", "Unfulfillable"].includes(r.status) &&
            r.total,
        )
        .map((r) => ({
          amazon_order_id: r.amazon_order_id,
          frete_estimado: 27.95,
          confirmado: false,
          fonte: "estimate",
        }));
      if (freteRows.length > 0) {
        await rpc<number>("az_upsert_frete", { p_rows: freteRows });
        frete_estimados = freteRows.length;
      }
    }

    return json({
      dia,
      pedidos: upserted,
      valor: Math.round(sumBruta(rows) * 100) / 100,
      status_counts: countStatuses(rows),
      comissao_estimadas,
      frete_estimados,
      itens_gravados,
    });
  }

  if (modo === "confirmar") {
    const result = await confirmAll(token);
    return json(result);
  }

  if (modo === "backfill") {
    const from = body.from;
    const to = body.to;
    if (!from || !to)
      return json({ error: "backfill requer from e to (YYYY-MM-DD)" }, 400);

    const { orders, error } = await fetchOrders(
      token,
      `${from}T00:00:00-03:00`,
      `${to}T23:59:59.999-03:00`,
    );
    if (error) return json({ error, parcial: orders.length }, 502);

    const rows = mapOrders(orders);
    let upserted = 0;
    if (rows.length > 0) {
      upserted = await rpc<number>("az_upsert_pedidos", { p_rows: rows });
    }

    return json({
      from,
      to,
      pedidos: upserted,
      valor: Math.round(sumBruta(rows) * 100) / 100,
      status_counts: countStatuses(rows),
    });
  }

  return json({ error: `modo desconhecido: ${modo}` }, 400);
});
