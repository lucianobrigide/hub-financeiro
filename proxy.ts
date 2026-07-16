import { NextRequest, NextResponse } from "next/server";

// Código de acesso pessoal ao hub. Override via env SITE_ACCESS_CODE na Vercel.
const ACCESS_CODE = process.env.SITE_ACCESS_CODE ?? "1914";
const COOKIE = "hub_auth";

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

  if (req.cookies.get(COOKIE)?.value === ACCESS_CODE) {
    return NextResponse.next();
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
