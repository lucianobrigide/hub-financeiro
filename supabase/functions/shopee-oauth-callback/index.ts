import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// OAuth callback Shopee — recebe code + shop_id do redirect,
// delega a troca ao RPC shopee_exchange_code (partner_key nunca sai do PG).
// Todas as chamadas HTTP à Shopee saem do PG (IP fixo do DB).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const code = url.searchParams.get("code");
  const shopId = url.searchParams.get("shop_id");
  const error = url.searchParams.get("error");

  if (error) {
    return json(
      { error, description: url.searchParams.get("error_description") },
      400,
    );
  }
  if (!code || !shopId) {
    return json(
      { error: "missing_params", hint: "redirecione via URL de autorizacao da Shopee (precisa de code + shop_id)" },
      400,
    );
  }

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/shopee_exchange_code`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_code: code, p_shop_id: parseInt(shopId, 10) }),
  });

  const result = await resp.json().catch(() => null);

  if (!resp.ok || !result?.ok) {
    return json(
      { error: "exchange_failed", detail: result },
      resp.ok ? 502 : resp.status,
    );
  }

  return json({
    ok: true,
    expires_in: result.expires_in,
    shop_id: result.shop_id,
    hint: "tokens salvos — access em shopee_oauth_state, refresh no Vault",
  });
});
