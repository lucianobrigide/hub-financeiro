import { dataProvider } from "@/lib/data";
import { RecebiveisPorPlataforma } from "@/components/RecebiveisPorPlataforma";
import { SaidasProjetadas } from "@/components/SaidasProjetadas";
import { SaldoProjetado } from "@/components/SaldoProjetado";
import { COLORS } from "@/components/ui";

// Server component: puxa os três blocos direto do provider (padrão do Hub, igual /crons).
// Rota dinâmica — recebível/saída/saldo é dado vivo, nunca cacheado.
export const dynamic = "force-dynamic";

export default async function FluxoCaixaPage() {
  const [recebiveis, saidas, saldo, historico] = await Promise.all([
    dataProvider.getRecebiveis?.() ?? Promise.resolve(null),
    dataProvider.getSaidasProjetadas?.() ?? Promise.resolve(null),
    dataProvider.getSaldoCaixa?.() ?? Promise.resolve(null),
    dataProvider.getFcHistorico?.() ?? Promise.resolve(null),
  ]);

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-xl font-bold text-white">Fluxo de Caixa Projetado</h1>
        <p className="mt-1 text-sm" style={{ color: COLORS.muted }}>
          O que já foi vendido e ainda vai cair na conta, o que já está lançado para sair, e o
          saldo que sobra dia a dia. Só fato com data entra na curva — nenhum valor é estimado;
          o que não tem data fica listado à parte.
        </p>
      </div>

      <SaldoProjetado recebiveis={recebiveis} saidas={saidas} saldo={saldo} historico={historico} />

      <RecebiveisPorPlataforma dados={recebiveis} />

      <SaidasProjetadas dados={saidas} />
    </div>
  );
}
