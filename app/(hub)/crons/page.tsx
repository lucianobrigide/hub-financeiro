import { dataProvider } from "@/lib/data";
import { CronsBoard } from "@/components/CronsBoard";

// Server component: puxa a saúde dos crons direto do provider (padrão do Hub).
// Rota dinâmica — sempre dado fresco (o rpc usa cache: no-store).
export const dynamic = "force-dynamic";

export default async function CronsPage() {
  const status = (await dataProvider.getCronsStatus?.()) ?? null;
  return <CronsBoard status={status} />;
}
