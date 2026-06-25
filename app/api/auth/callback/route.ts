import { NextResponse } from "next/server";

// Callback do OAuth do Mercado Livre (Authorization Code).
// O ML redireciona o usuário para cá com ?code=..., trocamos o code pelo par
// de tokens e gravamos em ml_tokens. Tudo server-side — tokens nunca voltam
// na resposta; o navegador só recebe um redirect para / com status.

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
      console.error(
        "Env ausente: ML_CLIENT_SECRET ou SUPABASE_SERVICE_ROLE_KEY.",
      );
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
    const userId = data.user_id as number | string | undefined;
    if (!accessToken || !refreshToken || !expiresIn) {
      console.error("Resposta do ML incompleta na troca de code.");
      return redirectTo("error");
    }
    const expiresAt = new Date(Date.now() + expiresIn * 1000).toISOString();

    // (3) Grava em ml_tokens via PostgREST usando o service_role key.
    //     service_role ignora RLS (a policy nega anon, não service_role).
    const insertResp = await fetch(`${SUPABASE_URL}/rest/v1/ml_tokens`, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify({
        user_id: String(userId ?? "unknown"),
        access_token: accessToken,
        refresh_token: refreshToken,
        expires_at: expiresAt,
      }),
    });

    if (!insertResp.ok) {
      console.error(`Insert em ml_tokens falhou: ${insertResp.status}.`);
      return redirectTo("error");
    }

    // (4) Sucesso — redireciona para / sem expor nenhum token.
    return redirectTo("success");
  } catch (err) {
    console.error("Erro no callback OAuth do ML:", err);
    return redirectTo("error");
  }
}
