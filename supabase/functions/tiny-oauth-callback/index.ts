import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// OAuth callback TINY (Olist) — recebe o code do redirect Keycloak,
// delega a troca ao RPC tiny_exchange_code (client_secret nunca sai do PG).
// Resultado: access_token em tiny_oauth_state, refresh_token no Vault.

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
      { error: "missing_code", hint: "redirecione via URL de autorizacao do TINY" },
      400,
    );
  }

  const redirectUri = `${SUPABASE_URL}/functions/v1/tiny-oauth-callback`;

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/tiny_exchange_code`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_code: code, p_redirect_uri: redirectUri }),
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
    scope: result.scope,
    hint: "tokens salvos — access em tiny_oauth_state, refresh no Vault",
  });
});
