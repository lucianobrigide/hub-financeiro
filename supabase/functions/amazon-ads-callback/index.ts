import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// OAuth callback Amazon Ads (LwA) — padrão tt-oauth-callback, independe da Vercel.
// Recebe o code do redirect e delega a troca ao RPC azads_exchange_code
// (client_secret nunca sai do Postgres/Vault). Code é de uso único e expira em
// minutos: troca imediata, falha ALTA (JSON com o motivo + oauth_refresh_log).
// Precisa estar cadastrada como Allowed Return URL no security profile LwA:
//   https://klwczmapuupensozxbsr.supabase.co/functions/v1/amazon-ads-callback

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const EXPECTED_STATE = "azads-hubfin";
const SELF_URL = `${SUPABASE_URL}/functions/v1/amazon-ads-callback`;

const restHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Amazon sinaliza recusa/erro via query própria.
  const oauthError = url.searchParams.get("error");
  if (oauthError) {
    return json(
      { ok: false, error: oauthError, description: url.searchParams.get("error_description") },
      400,
    );
  }

  // state fixo documentado — rejeita hits que não vieram do nosso fluxo.
  if (url.searchParams.get("state") !== EXPECTED_STATE) {
    return json({ ok: false, error: "state_invalido" }, 400);
  }

  const code = url.searchParams.get("code");
  if (!code) {
    return json(
      { ok: false, error: "missing_code", hint: "abrir via URL de autorizacao da Amazon" },
      400,
    );
  }

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/azads_exchange_code`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_code: code, p_redirect_uri: SELF_URL }),
  });
  const result = await resp.json().catch(() => null);

  if (!resp.ok || !result?.ok) {
    return json({ ok: false, error: "exchange_failed", detail: result }, resp.ok ? 502 : resp.status);
  }

  // Sucesso — nenhum token na resposta; custódia é toda do Supabase daqui em diante.
  return json({
    ok: true,
    message: "Amazon Ads autorizada. Tokens no Vault; pode fechar esta aba.",
    expires_at: result.expires_at,
  });
});
