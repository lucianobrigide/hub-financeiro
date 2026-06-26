"use server";

import { dataProvider } from "@/lib/data";
import type { DashboardData } from "@/lib/data/types";

// Server Action: o dropdown (client) chama isto ao trocar o mês. O dataProvider
// roda SÓ no servidor — o client nunca importa lib/data (que puxa server-only).
export async function fetchDashboardAction(month: string): Promise<DashboardData> {
  return dataProvider.getDashboard(month);
}
