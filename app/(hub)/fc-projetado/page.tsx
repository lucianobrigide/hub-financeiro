import { dataProvider } from "@/lib/data";
import { RecebiveisPorPlataforma } from "@/components/RecebiveisPorPlataforma";
import { COLORS, Panel } from "@/components/ui";

// Server component: puxa os recebíveis direto do provider (padrão do Hub, igual /crons).
// Rota dinâmica — recebível é dado vivo, nunca cacheado.
export const dynamic = "force-dynamic";

export default async function FluxoCaixaPage() {
  const recebiveis = (await dataProvider.getRecebiveis?.()) ?? null;

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-white">Fluxo de Caixa Projetado</h1>
        <p className="mt-1 text-sm" style={{ color: COLORS.muted }}>
          O que já foi vendido e ainda vai cair na conta, por plataforma e por data
          de liberação. Cada plataforma entra quando a integração dela existir —
          nenhum valor é estimado.
        </p>
      </div>

      <RecebiveisPorPlataforma dados={recebiveis} />

      <Panel title="Ainda não construído">
        <p className="text-sm" style={{ color: COLORS.muted }}>
          Faltam as <strong style={{ color: COLORS.white }}>saídas projetadas</strong>{" "}
          (contas a pagar da Omie) e o{" "}
          <strong style={{ color: COLORS.white }}>saldo projetado por dia</strong>{" "}
          (recebíveis − saídas + saldo em conta). Entram depois que os recebíveis
          das plataformas estiverem ligados.
        </p>
      </Panel>
    </div>
  );
}
