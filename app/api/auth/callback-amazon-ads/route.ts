import { NextResponse } from "next/server";

// Callback do OAuth da Amazon Ads API (Authorization Code) — executa UMA vez
// para inicializar a cadeia de tokens. Diferente do callback do ML, a troca do
// code acontece DENTRO do Postgres (RPC azads_exchange_code): o client_secret
// vive só no Vault e nunca passa pela Vercel. O code é de uso único e expira em
// minutos — a troca é imediata e a falha é ALTA (JSON 502 com o motivo, nada de
// redirect silencioso). Nenhum token volta na resposta.

const EXPECTED_STATE = "azads-hubfin";

// URL do projeto Supabase (não é segredo). Pode ser sobrescrita por env.
const SUPABASE_URL =
  process.env.SUPABASE_URL ?? "https://klwczmapuupensozxbsr.supabase.co";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const fail = (status: number, body: Record<string, unknown>) => {
    console.error("Callback Amazon Ads FALHOU:", JSON.stringify(body));
    return NextResponse.json({ ok: false, ...body }, { status });
  };

  try {
    // (1) Amazon sinaliza recusa/erro via query própria.
    const oauthError = url.searchParams.get("error");
    if (oauthError) {
      return fail(400, {
        error: oauthError,
        description: url.searchParams.get("error_description"),
      });
    }

    // (2) state fixo documentado — rejeita hits que não vieram do nosso fluxo.
    if (url.searchParams.get("state") !== EXPECTED_STATE) {
      return fail(400, { error: "state_invalido" });
    }

    const code = url.searchParams.get("code");
    if (!code) {
      return fail(400, { error: "missing_code" });
    }

    const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!serviceRoleKey) {
      return fail(500, { error: "env_ausente", detail: "SUPABASE_SERVICE_ROLE_KEY" });
    }

    // (3) Troca imediata via RPC (client_secret só no Vault; log em oauth_refresh_log).
    const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/azads_exchange_code`, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_code: code,
        // O redirect_uri da troca TEM que ser o mesmo do authorize. Esta rota é o
        // caminho alternativo (Vercel); o principal é a Edge amazon-ads-callback.
        p_redirect_uri:
          "https://hub-financeiro-omega.vercel.app/api/auth/callback-amazon-ads",
      }),
    });
    const result = await resp.json().catch(() => null);

    if (!resp.ok || !result?.ok) {
      return fail(502, { error: "exchange_failed", detail: result });
    }

    // (4) Sucesso — nenhum token na resposta; cadeia agora é custódia do Supabase.
    return NextResponse.redirect(new URL("/?auth=success&src=amazon-ads", request.url));
  } catch (err) {
    return fail(500, { error: "exception", detail: String(err) });
  }
}
