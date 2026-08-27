import { cookies } from "next/headers";
import { dataProvider } from "@/lib/data";
import { DashboardProvider } from "@/components/DashboardProvider";
import { Sidebar } from "@/components/Sidebar";
import { HubMain } from "./HubMain";

// Sem isto, o build da Vercel prerenderiza `/`, `/dre` e `/marketplaces/*` como
// estáticas e o dashboard serviria o snapshot do momento do build (com DATA_SOURCE
// ausente no build, seria o mock) até o usuário trocar o mês.
export const dynamic = "force-dynamic";

export default async function HubLayout({ children }: { children: React.ReactNode }) {
  const months = (await dataProvider.listAvailableMonths?.()) ?? [];
  const mesCorrente = new Date()
    .toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" })
    .slice(0, 7);
  const initialMonth = (months.find((m) => m.value !== mesCorrente) ?? months[0])?.value;
  const data = await dataProvider.getDashboard(initialMonth);

  // Perfil equipe: cookie do código restrito (o bloqueio real das rotas fica no proxy.ts).
  const teamCode = process.env.SITE_ACCESS_CODE_EQUIPE;
  const cookieStore = await cookies();
  const equipe = Boolean(teamCode) && cookieStore.get("hub_auth")?.value === teamCode;

  return (
    <DashboardProvider initialData={data} months={months} initialMonth={initialMonth}>
      <div
        className="flex min-h-screen font-sans"
        style={{ background: "#0a0e1a", color: "#ffffff" }}
      >
        <Sidebar equipe={equipe} />
        <HubMain>{children}</HubMain>
      </div>
    </DashboardProvider>
  );
}
