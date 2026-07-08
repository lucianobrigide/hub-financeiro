import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Porta de LEITURA do token OAuth da Shopee (get-or-refresh) + assinatura HMAC.
// 1) lê shopee_oauth_state; 2) cache válido (folga 30 min) devolve sem rotacionar;
// 3) senão delega ao RPC shopee_refresh_token e relê.
// Se query param ?path= fornecido, retorna params assinados (HMAC) para a chamada.
// Auth por x-api-key validada via shopee_token_check.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SKEW_MS = 30 * 60 * 1000;

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

type State = { access_token: string | null; shop_id: number | null; expires_at: string | null };

async function readState(): Promise<State | null> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/shopee_get_state`, {
    method: "POST", headers: restHeaders, body: "{}",
  });
  if (!resp.ok) return null;
  const rows = await resp.json().catch(() => null);
  return Array.isArray(rows) && rows.length ? (rows[0] as State) : null;
}

async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/shopee_token_check`, {
    method: "POST", headers: restHeaders, body: JSON.stringify({ p_key: candidate }),
  });
  if (!resp.ok) return false;
  return (await resp.json().catch(() => false)) === true;
}

async function getSignedParams(path: string): Promise<Record<string, unknown> | null> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/shopee_signed_params`, {
    method: "POST", headers: restHeaders, body: JSON.stringify({ p_path: path }),
  });
  if (!resp.ok) return null;
  return await resp.json().catch(() => null);
}

const isFresh = (s: State | null) =>
  !!s?.access_token && !!s.expires_at && new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;

Deno.serve(async (req) => {
  if (!(await keyIsValid(req.headers.get("x-api-key")))) {
    return json({ error: "nao autorizado" }, 401);
  }

  let state = await readState();
  let refreshed = false;

  if (!isFresh(state)) {
    const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/shopee_refresh_token`, {
      method: "POST", headers: restHeaders, body: JSON.stringify({ p_force: false }),
    });
    const result = await rpc.json().catch(() => null);
    if (result && result.valid === false) {
      return json({
        error: result.error ?? "refresh_failed",
        action: result.action,
        hint: result.error === "shop_not_authorized" || result.error === "refresh_token_not_seeded"
          ? "Autorize o app Shopee primeiro via shopee_auth_url()."
          : "Verifique vault.secrets (shopee_*) e public.oauth_refresh_log.",
      }, 502);
    }
    state = await readState();
    if (!isFresh(state)) {
      return json({ error: "token_indisponivel", hint: "consulte public.oauth_refresh_log" }, 502);
    }
    refreshed = Boolean(result?.refreshed);
  }

  const reqUrl = new URL(req.url);
  const apiPath = reqUrl.searchParams.get("path");

  if (apiPath) {
    const signed = await getSignedParams(apiPath);
    if (!signed || signed.error) {
      return json({ error: "sign_failed", detail: signed }, 500);
    }
    return json({ ...signed, refreshed });
  }

  return json({
    access_token: state!.access_token,
    shop_id: state!.shop_id,
    expires_at: state!.expires_at,
    refreshed,
  });
});
