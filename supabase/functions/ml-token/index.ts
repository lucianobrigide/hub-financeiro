import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// Porta de LEITURA do token OAuth do Mercado Livre (get-or-refresh).
// 1) lê ml_oauth_state; 2) se o cache é válido (folga de 10 min) devolve sem
// rotacionar; 3) senão delega ao RPC atômico public.ml_refresh_token e relê.
// Nunca toca no refresh_token (esse vive só no Vault). Auth por x-api-key
// validada no Vault via RPC public.ml_token_check.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SKEW_MS = 10 * 60 * 1000; // cache válido só se faltar mais que isto p/ expirar

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

type State = {
  access_token: string | null;
  expires_at: string | null;
  user_id: string | null;
};

async function readState(): Promise<State | null> {
  // Leitura via RPC SECURITY DEFINER (ml_get_state) — não depende de o
  // service_role furar a RLS no SELECT direto via PostgREST.
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_get_state`, {
    method: "POST",
    headers: restHeaders,
    body: "{}",
  });
  if (!resp.ok) return null;
  const rows = await resp.json().catch(() => null);
  return Array.isArray(rows) && rows.length ? (rows[0] as State) : null;
}

// valida o x-api-key contra o Vault via RPC (retorna boolean; segredo fica no banco)
async function keyIsValid(candidate: string | null): Promise<boolean> {
  if (!candidate) return false;
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_token_check`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_key: candidate }),
  });
  if (!resp.ok) return false;
  return (await resp.json().catch(() => false)) === true;
}

function isFresh(s: State | null): boolean {
  if (!s?.access_token || !s.expires_at) return false;
  return new Date(s.expires_at).getTime() - Date.now() > SKEW_MS;
}

Deno.serve(async (req) => {
  // ---- auth (segredo compartilhado, validado no Vault) ----
  if (!(await keyIsValid(req.headers.get("x-api-key")))) {
    return json({ error: "nao autorizado" }, 401);
  }

  // ---- 1) hot path: cache em ml_oauth_state ----
  let state = await readState();
  if (isFresh(state)) {
    return json({
      access_token: state!.access_token,
      expires_at: state!.expires_at,
      user_id: state!.user_id,
      refreshed: false,
    });
  }

  // ---- 2) get-or-refresh: delega ao RPC atômico + lockado ----
  const rpc = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_refresh_token`, {
    method: "POST",
    headers: restHeaders,
    body: JSON.stringify({ p_force: false }),
  });
  const result = await rpc.json().catch(() => null);
  if (result && result.valid === false) {
    const broken = result.error === "invalid_grant";
    return json(
      {
        error: result.error ?? "refresh_failed",
        action: result.action,
        hint: broken
          ? "Cadeia de refresh quebrada — reautorizar manualmente o app ML."
          : "Verifique vault.secrets (ml_*) e public.oauth_refresh_log.",
      },
      broken ? 409 : 502,
    );
  }

  // ---- 3) relê o estado e devolve o token quente ----
  state = await readState();
  if (!isFresh(state)) {
    return json(
      { error: "token_indisponivel", hint: "consulte public.oauth_refresh_log" },
      502,
    );
  }
  return json({
    access_token: state!.access_token,
    expires_at: state!.expires_at,
    user_id: state!.user_id,
    refreshed: Boolean(result?.refreshed),
  });
});
