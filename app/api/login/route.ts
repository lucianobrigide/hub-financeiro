import { NextRequest, NextResponse } from "next/server";

const ACCESS_CODE = process.env.SITE_ACCESS_CODE ?? "1914";
// Código da equipe (perfil restrito) — só existe se a env estiver definida.
const TEAM_CODE = process.env.SITE_ACCESS_CODE_EQUIPE;
// Código da Fernanda (acesso completo) — idem, só existe com a env definida.
const FERNANDA_CODE = process.env.SITE_ACCESS_CODE_FERNANDA;
const COOKIE = "hub_auth";

export async function POST(req: NextRequest) {
  const form = await req.formData();
  const code = String(form.get("code") ?? "").trim();
  const next = String(form.get("next") ?? "/") || "/";

  const valido =
    code === ACCESS_CODE ||
    (Boolean(TEAM_CODE) && code === TEAM_CODE) ||
    (Boolean(FERNANDA_CODE) && code === FERNANDA_CODE);
  if (!valido) {
    const url = req.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("next", next);
    url.searchParams.set("erro", "1");
    return NextResponse.redirect(url, { status: 303 });
  }

  const url = req.nextUrl.clone();
  url.pathname = next.startsWith("/") ? next : "/";
  url.search = "";
  const res = NextResponse.redirect(url, { status: 303 });
  res.cookies.set(COOKIE, code, {
    httpOnly: true,
    secure: true,
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 90, // 90 dias
  });
  return res;
}
