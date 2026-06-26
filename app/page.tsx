import { dataProvider } from "@/lib/data";
import { Dashboard } from "@/components/Dashboard";

export default async function Home() {
  const months = (await dataProvider.listAvailableMonths?.()) ?? [];
  const initialMonth = months[0]?.value; // mais recente = mês atual
  const data = await dataProvider.getDashboard(initialMonth);
  return <Dashboard initialData={data} months={months} initialMonth={initialMonth} />;
}
