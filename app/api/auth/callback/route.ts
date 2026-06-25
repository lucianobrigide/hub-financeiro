import { NextResponse } from "next/server";

// Callback do OAuth do Mercado Livre (Authorization Code) — executa UMA vez para
// inicializar a cadeia de tokens. Troca o code pelo par de tokens e SEMEIA o
// Vault via RPC ml_seed_initial (service_role). A partir daí, a custódia é toda
// do Supabase: refresh_token vive só no Vault; quem precisa de access_token usa
// a Edge Function ml-token. Tudo server-side — nenhum token volta na resposta.

const ML_TOKEN_URL = "https://api.mercadolibre.com/oauth/token";
const ML_CLIENT_ID = "7148019439656171";
const ML_REDIRECT_URI = "https://hub-financeiro-omega.vercel.app/api/auth/callback";

// URL do projeto Supabase (não é segredo). Pode ser sobrescrita por env.
const SUPABASE_URL =
  process.env.SUPABASE_URL ?? "https://klwczmapuupensozxbsr.supabase.co";

export async function GET(request: Request) {
  // Sempre voltamos para / sinalizando o resultado via query (?auth=...).
  const redirectTo = (status: "success" | "error") =>
    NextResponse.redirect(new URL(`/?auth=${status}`, request.url));

  try {
    // (1) Lê o code enviado pelo Mercado Livre.
    const code = new URL(request.url).searchParams.get("code");
    if (!code) {
      console.error("Callback ML sem parâmetro 'code'.");
      return redirectTo("error");
    }

    const clientSecret = process.env.ML_CLIENT_SECRET;
    const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!clientSecret || !serviceRoleKey) {
      console.error("Env ausente: ML_CLIENT_SECRET ou SUPABASE_SERVICE_ROLE_KEY.");
      return redirectTo("error");
    }

    // (2) Troca o code por access_token + refresh_token.
    const tokenResp = await fetch(ML_TOKEN_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: ML_CLIENT_ID,
        client_secret: clientSecret,
        code,
        redirect_uri: ML_REDIRECT_URI,
      }),
    });

    if (!tokenResp.ok) {
      console.error(`Troca de code falhou: ML respondeu ${tokenResp.status}.`);
      return redirectTo("error");
    }

    const data = await tokenResp.json();
    const accessToken = data.access_token as string | undefined;
    const refreshToken = data.refresh_token as string | undefined;
    const expiresIn = data.expires_in as number | undefined;
    const tokenType = data.token_type as string | undefined;
    const scope = data.scope as string | undefined;
    const userId = data.user_id as number | string | undefined;
    if (!accessToken || !refreshToken || !expiresIn) {
      console.error("Resposta do ML incompleta na troca de code.");
      return redirectTo("error");
    }

    // (3) Semeia o Vault (credenciais + refresh_token) e grava o access_token
    //     inicial em ml_oauth_state — tudo via RPC SECURITY DEFINER, com service_role.
    const seedResp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ml_seed_initial`, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_client_id: ML_CLIENT_ID,
        p_client_secret: clientSecret,
        p_refresh_token: refreshToken,
        p_access_token: accessToken,
        p_token_type: tokenType ?? null,
        p_scope: scope ?? null,
        p_expires_in: expiresIn,
        p_user_id: userId != null ? String(userId) : null,
      }),
    });

    if (!seedResp.ok) {
      console.error(`Seed do Vault falhou: ${seedResp.status}.`);
      return redirectTo("error");
    }

    // (4) Sucesso — redireciona para / sem expor nenhum token.
    return redirectTo("success");
  } catch (err) {
    console.error("Erro no callback OAuth do ML:", err);
    return redirectTo("error");
  }
}
