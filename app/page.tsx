import { dataProvider } from "@/lib/data";
import { Dashboard } from "@/components/Dashboard";

export default async function Home() {
  const months = (await dataProvider.listAvailableMonths?.()) ?? [];
  // Default = último mês FECHADO: pula o mês corrente (parcial). months vem do mais
  // recente pro mais antigo; o seletor ainda permite abrir o mês corrente.
  const mesCorrente = new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }).slice(0, 7);
  const initialMonth = (months.find((m) => m.value !== mesCorrente) ?? months[0])?.value;
  const data = await dataProvider.getDashboard(initialMonth);
  return <Dashboard initialData={data} months={months} initialMonth={initialMonth} />;
}
