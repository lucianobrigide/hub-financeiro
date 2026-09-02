import { NextRequest, NextResponse } from "next/server";

// Código de acesso pessoal ao hub. Override via env SITE_ACCESS_CODE na Vercel.
const ACCESS_CODE = process.env.SITE_ACCESS_CODE ?? "1914";
// Código da equipe (acesso restrito: só Home e Marketplaces). Sem fallback:
// enquanto a env SITE_ACCESS_CODE_EQUIPE não existir, esse perfil não existe.
const TEAM_CODE = process.env.SITE_ACCESS_CODE_EQUIPE;
// Código da Fernanda (acesso completo, revogável sem trocar o código pessoal).
const FERNANDA_CODE = process.env.SITE_ACCESS_CODE_FERNANDA;
const FULL_CODES = [ACCESS_CODE, FERNANDA_CODE].filter(Boolean) as string[];
const COOKIE = "hub_auth";

// Prefixos que o perfil equipe pode abrir (além de /, liberado à parte).
const TEAM_ALLOWED = ["/marketplaces"];

export function proxy(req: NextRequest) {
  const { pathname, hostname } = req.nextUrl;

  // Dev local: sem gate. O token só vale quando estiver online (produção).
  if (hostname === "localhost" || hostname === "127.0.0.1") {
    return NextResponse.next();
  }

  // Rotas liberadas: tela de login, endpoint de login e o callback OAuth do ML.
  if (
    pathname === "/login" ||
    pathname.startsWith("/api/login") ||
    pathname.startsWith("/api/auth/")
  ) {
    return NextResponse.next();
  }

  const cookie = req.cookies.get(COOKIE)?.value;

  if (cookie && FULL_CODES.includes(cookie)) {
    return NextResponse.next();
  }

  if (TEAM_CODE && cookie === TEAM_CODE) {
    if (pathname === "/" || TEAM_ALLOWED.some((p) => pathname.startsWith(p))) {
      return NextResponse.next();
    }
    // Página fora do perfil: volta para a Home em vez da tela de login.
    const url = req.nextUrl.clone();
    url.pathname = "/";
    url.search = "";
    return NextResponse.redirect(url);
  }

  const url = req.nextUrl.clone();
  url.pathname = "/login";
  url.searchParams.set("next", pathname);
  return NextResponse.redirect(url);
}

export const config = {
  // Protege tudo, menos assets estáticos do Next e o favicon.
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
