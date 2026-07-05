import { dataProvider } from "@/lib/data";
import { DashboardProvider } from "@/components/DashboardProvider";
import { Sidebar } from "@/components/Sidebar";
import { HubMain } from "./HubMain";

export default async function HubLayout({ children }: { children: React.ReactNode }) {
  const months = (await dataProvider.listAvailableMonths?.()) ?? [];
  const mesCorrente = new Date()
    .toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" })
    .slice(0, 7);
  const initialMonth = (months.find((m) => m.value !== mesCorrente) ?? months[0])?.value;
  const data = await dataProvider.getDashboard(initialMonth);

  return (
    <DashboardProvider initialData={data} months={months} initialMonth={initialMonth}>
      <div
        className="flex min-h-screen font-sans"
        style={{ background: "#0a0e1a", color: "#ffffff" }}
      >
        <Sidebar />
        <HubMain>{children}</HubMain>
      </div>
    </DashboardProvider>
  );
}
