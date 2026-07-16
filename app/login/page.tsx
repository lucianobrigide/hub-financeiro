import { COLORS } from "@/components/ui";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; erro?: string }>;
}) {
  const { next = "/", erro } = await searchParams;

  return (
    <div
      className="flex min-h-screen flex-col items-center justify-center px-4"
      style={{ background: COLORS.bg }}
    >
      <div
        className="w-full max-w-sm rounded-2xl border p-8"
        style={{ background: COLORS.panel, borderColor: COLORS.panelBorder }}
      >
        <h1 className="text-lg font-bold" style={{ color: COLORS.cyan }}>
          Hub Financeiro
        </h1>
        <p className="mt-1 text-sm" style={{ color: COLORS.muted }}>
          Digite o token de acesso.
        </p>

        <form action="/api/login" method="POST" className="mt-6 space-y-4">
          <input type="hidden" name="next" value={next} />
          <input
            name="code"
            type="password"
            inputMode="numeric"
            autoComplete="off"
            autoFocus
            placeholder="Token"
            className="w-full rounded-lg border px-4 py-3 text-center text-lg tracking-widest text-white outline-none"
            style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}
          />
          {erro && (
            <p className="text-center text-xs" style={{ color: COLORS.red }}>
              Token inválido.
            </p>
          )}
          <button
            type="submit"
            className="w-full rounded-lg py-3 text-sm font-semibold"
            style={{ background: COLORS.cyan, color: COLORS.bg }}
          >
            Entrar
          </button>
        </form>
      </div>
    </div>
  );
}
