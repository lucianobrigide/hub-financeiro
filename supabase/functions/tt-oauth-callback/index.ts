import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// OAuth callback TikTok Shop — recebe code do redirect,
// delega a troca ao RPC tt_exchange_code (app_secret nunca sai do PG).
// Também busca shop_cipher via Get Authorized Shops automaticamente.

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
  const error = url.searchParams.get("error");

  if (error) {
    return json(
      { error, description: url.searchParams.get("error_description") },
      400,
    );
  }
  if (!code) {
    return json(
      { error: "missing_code", hint: "redirecione via URL de autorizacao do TikTok Shop" },
      400,
    );
  }

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/tt_exchange_code`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_code: code }),
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
    expires_at: result.expires_at,
    seller_name: result.seller_name,
    shop_cipher: result.shop_cipher,
    hint: "tokens salvos — access em tt_oauth_state, refresh no Vault",
  });
});
