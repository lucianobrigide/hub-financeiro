import { dataProvider } from "@/lib/data";
import { Dashboard } from "@/components/Dashboard";

export default async function Home() {
  const data = await dataProvider.getDashboard();
  return <Dashboard data={data} />;
}
