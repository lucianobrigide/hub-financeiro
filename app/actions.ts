"use server";

import { dataProvider } from "@/lib/data";
import type { DashboardData, SkuDre } from "@/lib/data/types";

// Server Action: o dropdown (client) chama isto ao trocar o mês. O dataProvider
// roda SÓ no servidor — o client nunca importa lib/data (que puxa server-only).
export async function fetchDashboardAction(month: string): Promise<DashboardData> {
  return dataProvider.getDashboard(month);
}

// Server Action: DRE por SKU de um canal no mês (seção sob demanda nas páginas de canal).
export async function fetchDreSkuAction(canal: string, month: string): Promise<SkuDre[]> {
  return (await dataProvider.getDreSku?.(canal, month)) ?? [];
}
