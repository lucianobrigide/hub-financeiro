"use server";

import { dataProvider } from "@/lib/data";
import type { DashboardData, DreDrift, DreItem, SkuDre } from "@/lib/data/types";

// Server Action: o dropdown (client) chama isto ao trocar o mês. O dataProvider
// roda SÓ no servidor — o client nunca importa lib/data (que puxa server-only).
export async function fetchDashboardAction(month: string): Promise<DashboardData> {
  return dataProvider.getDashboard(month);
}

// Server Action: DRE por SKU de um canal no mês (seção sob demanda nas páginas de canal).
export async function fetchDreSkuAction(canal: string, month: string): Promise<SkuDre[]> {
  return (await dataProvider.getDreSku?.(canal, month)) ?? [];
}

// Server Action: linhas do DRE preenchíveis pela Omie (Grupo R) no mês. Mapa dre_code -> valor.
export async function fetchDreGrupoRAction(month: string): Promise<Record<string, number>> {
  return (await dataProvider.getDreGrupoR?.(month)) ?? {};
}

// Server Action: subcategorias (drill-down) das linhas do DRE da Omie no mês.
export async function fetchDreGrupoRDetalheAction(
  month: string,
): Promise<{ dre_code: string; nome: string; valor: number }[]> {
  return (await dataProvider.getDreGrupoRDetalhe?.(month)) ?? [];
}

// Server Action: 3º nível — despesas unitárias de uma (linha × categoria) no mês.
export async function fetchDreItensAction(
  month: string,
  dreCode: string,
  categoria: string,
): Promise<DreItem[]> {
  return (await dataProvider.getDreItens?.(month, dreCode, categoria)) ?? [];
}

// Server Action: trava de fechamento — vivo × snapshot congelado do mês (selo do /dre).
export async function fetchDreDriftAction(month: string): Promise<DreDrift | null> {
  return (await dataProvider.getDreDrift?.(month)) ?? null;
}

// Server Action: DRE completo do mês. Junta o topo (Hub, acima da MC) com o detalhe do
// Grupo R (Omie). Funde o ADS de marketplace como subcategoria do C1 (Marketing & Tráfego),
// pra a soma das subcategorias fechar com o total da linha.
export async function fetchDreCompletoAction(month: string): Promise<{
  topo: Record<string, number>;
  detalhe: { dre_code: string; nome: string; valor: number }[];
}> {
  const topo = (await dataProvider.getDreTopo?.(month)) ?? {};
  const detalhe = [...((await dataProvider.getDreGrupoRDetalhe?.(month)) ?? [])];
  // ADS de marketplace (Hub) vira subcategoria do C1, junto do marketing próprio (Omie).
  const ads = topo["Marketing & Tráfego"];
  if (ads) detalhe.push({ dre_code: "C1", nome: "ADS Marketplaces (Hub)", valor: ads });
  // DIFAL da plataforma (Hub) vira subcategoria do I1, junto do DIFAL pago por fora (Omie).
  const difalHub = topo["DIFAL"];
  if (difalHub) detalhe.push({ dre_code: "I1", nome: "DIFAL Plataforma (Hub)", valor: difalHub });
  const topoOut = { ...topo };
  delete topoOut["Marketing & Tráfego"]; // agora vive no C1 (via detalhe)
  delete topoOut["DIFAL"]; // agora vive no I1 (via detalhe)
  delete topoOut["Impostos s/ Vendas"]; // computado como soma dos filhos (DIFAL + IPI)
  return { topo: topoOut, detalhe };
}
