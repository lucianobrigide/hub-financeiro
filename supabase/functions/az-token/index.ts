import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Porta de LEITURA do token LWA da Amazon SP-API (get-or-refresh) — clone da ml-token.
// 1) lê az_oauth_state; 2) cache válido (folga 10 min) devolve sem rotacionar;
// 3) senão delega ao RPC atômico public.az_refresh_token e relê. O refresh_token LWA
// NÃO rotaciona (vive só no Vault). Auth por x-api-key validada via az_token_check.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
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

type State = { access_token: string | null; expires_at: string | null };

async function readState(): Promise<State | null> {
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/az_get_state`, {
    method: "POST", headers: restHeaders, body: "{}",
  });
  if (!resp.ok) return null;
  const rows = await resp.json().catch(() => null);
  return Array.isArray(rows) && rows.length ? (rows[0] as State) : null;
}

async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/az_token_check`, {
    method: "POST", headers: restHeaders, body: JSON.stringify({ p_key: candidate }),
  });
  if (!resp.ok) return false;
  return (await resp.json().catch(() => false)) === true;
}

const isFresh = (s: State | null) =>
  !!s?.access_token && !!s.expires_at && new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;

Deno.serve(async (req) => {
  if (!(await keyIsValid(req.headers.get("x-api-key")))) {
    return json({ error: "nao autorizado" }, 401);
  }

  let state = await readState();
  if (isFresh(state)) {
    return json({ access_token: state!.access_token, expires_at: state!.expires_at, refreshed: false });
  }

  const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/az_refresh_token`, {
    method: "POST", headers: restHeaders, body: JSON.stringify({ p_force: false }),
  });
  const result = await rpc.json().catch(() => null);
  if (result && result.valid === false) {
    return json({ error: result.error ?? "refresh_failed", hint: "verifique vault.secrets (az_*) e public.oauth_refresh_log" }, 502);
  }

  state = await readState();
  if (!isFresh(state)) {
    return json({ error: "token_indisponivel", hint: "consulte public.oauth_refresh_log" }, 502);
  }
  return json({ access_token: state!.access_token, expires_at: state!.expires_at, refreshed: Boolean(result?.refreshed) });
});
