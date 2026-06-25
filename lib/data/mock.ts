import type { DashboardData, DataProvider } from "./types";

/**
 * Dados mockados do dashboard.
 *
 * Foram extraídos integralmente do componente (antes hardcoded em
 * app/page.tsx). Esta é a ÚNICA fonte desses números agora.
 */
const DASHBOARD: DashboardData = {
  kpis: {
    totalVenda: 20641882.07,
    totalPedidos: 108104,
    ticketMedio: 190.94,
  },
  provavel: {
    mediaVendaDiaria: 110754.17,
    faturamentoCorrenteProvavel: 3322624.99,
    mcIdeal: 195000.0,
    pontoEquilibrio: 3902813.43,
    pontoEquilibrioPct: 85.13,
    retLMedio: 10.0,
    mcLMedia: 6.98,
    mcLUltMes: 5.0,
  },
  margemGauge: {
    valor: 166011.49,
    max: 214500, // R$ 214,50 Mil
  },
  mcMensal: [
    { valor: 351929.16, pct: 113.19 },
    { valor: 298943.15, pct: 84.18 },
    { valor: 348283.12, pct: 98.08 },
    { valor: 322421.66, pct: 90.79 },
    { valor: 166011.49, pct: 85.13 },
  ],
  totalMensal: [
    { mes: "Fev/26", venda: 2.55, mcVenda: 13.78, mcLiquida: 8.8 },
    { mes: "Mar/26", venda: 2.3, mcVenda: 12.97, mcLiquida: 7.01 },
    { mes: "Abr/26", venda: 2.41, mcVenda: 14.45, mcLiquida: 7.51 },
    { mes: "Mai/26", venda: 2.77, mcVenda: 11.65, mcLiquida: 6.34 },
    { mes: "Jun/26", venda: 2.49, mcVenda: 6.67, mcLiquida: 5.0 },
  ],
  plataformas: [
    { nome: "Mercado Livre", valor: 18766989.48 },
    { nome: "Shopee", valor: 1074496.25 },
    { nome: "Tik Tok", valor: 796985.74 },
    { nome: "Amazon", valor: 2191.1 },
    { nome: "Vendas Internas", valor: 1219.5 },
  ],
  vendasDiarias: [
    { data: "15/06", valor: 206708.39, pedidos: 1060 },
    { data: "14/06", valor: 176214.45, pedidos: 913 },
    { data: "13/06", valor: 138011.13, pedidos: 709 },
    { data: "12/06", valor: 227073.48, pedidos: 1151 },
    { data: "11/06", valor: 248764.08, pedidos: 1276 },
    { data: "10/06", valor: 199062.39, pedidos: 1034 },
  ],
};

/** Provider mockado — implementa o contrato DataProvider. */
export const mockProvider: DataProvider = {
  async getDashboard(): Promise<DashboardData> {
    return DASHBOARD;
  },
};
