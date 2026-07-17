import type { CronsStatus, DashboardData, DataProvider, Month, PlataformaDre } from "./types";

/** Labels das 6 deduções do mini-DRE, na ordem do card. */
const DEDUCAO_LABELS = ["Comissão", "Frete", "ADS", "Full", "Afiliados", "CMV"];
/** Plataformas do card, na ordem exibida. */
const PLATAFORMAS_DRE = ["Mercado Livre", "Shopee", "TikTok Shop", "Amazon", "B2B"];

/** DRE mock (tudo 0) — mantém o card idêntico ao que já mostrava. */
function mockDre(nome: string): PlataformaDre {
  return {
    nome,
    faturamentoBruto: 0,
    cancelDevolucoes: 0,
    faturamentoLiquido: 0,
    deducoes: DEDUCAO_LABELS.map((label) => ({ label, valor: 0 })),
    mc: 0,
  };
}

/**
 * Dados mockados do dashboard (BASE — mês "neutro").
 *
 * Foram extraídos integralmente do componente (antes hardcoded em
 * app/page.tsx). getDashboard(month) varia esses números por mês para dar
 * para ver a troca funcionando.
 */
const BASE: DashboardData = {
  kpis: {
    totalVenda: 20641882.07,
    totalPedidos: 108104,
    ticketMedio: 190.94,
    mcTotal: 1685000.0,
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
    { nome: "B2B", valor: 1219.5 },
  ],
  plataformasDre: PLATAFORMAS_DRE.map(mockDre),
  vendasDiarias: [
    { data: "15/06", valor: 206708.39, pedidos: 1060 },
    { data: "14/06", valor: 176214.45, pedidos: 913 },
    { data: "13/06", valor: 138011.13, pedidos: 709 },
    { data: "12/06", valor: 227073.48, pedidos: 1151 },
    { data: "11/06", valor: 248764.08, pedidos: 1276 },
    { data: "10/06", valor: 199062.39, pedidos: 1034 },
  ],
};

const MESES_FULL = [
  "Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho",
  "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro",
];

/** Últimos 12 meses até o mês atual, mais recente primeiro. */
function buildMonths(): Month[] {
  const now = new Date();
  const out: Month[] = [];
  for (let i = 0; i < 12; i++) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const value = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
    out.push({ value, label: `${MESES_FULL[d.getMonth()]} ${d.getFullYear()}` });
  }
  return out;
}

/** Fator determinístico por mês (~0.70..1.29) — mesmo mês, mesmo número. */
function factorFor(month?: string): number {
  if (!month) return 1;
  let h = 0;
  for (let i = 0; i < month.length; i++) h = (h * 31 + month.charCodeAt(i)) >>> 0;
  return 0.7 + (h % 60) / 100;
}

/** Deriva um DashboardData "do mês" escalando a BASE pelo fator. */
function dashboardFor(month?: string): DashboardData {
  const f = factorFor(month);
  const r = (n: number) => Math.round(n * f * 100) / 100;
  const ri = (n: number) => Math.round(n * f);
  return {
    kpis: {
      totalVenda: r(BASE.kpis.totalVenda),
      totalPedidos: ri(BASE.kpis.totalPedidos),
      ticketMedio: r(BASE.kpis.ticketMedio),
      mcTotal: null,
    },
    provavel: {
      ...BASE.provavel,
      mediaVendaDiaria: r(BASE.provavel.mediaVendaDiaria),
      faturamentoCorrenteProvavel: r(BASE.provavel.faturamentoCorrenteProvavel),
    },
    margemGauge: { ...BASE.margemGauge, valor: BASE.margemGauge.valor == null ? null : r(BASE.margemGauge.valor) },
    mcMensal: BASE.mcMensal.map((m) => ({ ...m, valor: r(m.valor) })),
    totalMensal: BASE.totalMensal.map((m) => ({
      ...m,
      venda: Math.round(m.venda * f * 100) / 100,
    })),
    plataformas: BASE.plataformas.map((p) => ({ ...p, valor: p.valor == null ? null : r(p.valor) })),
    // DRE mock permanece 0 (escalar 0 = 0) — card idêntico ao existente, sob mock nada muda.
    plataformasDre: BASE.plataformasDre.map((d) => ({ ...d })),
    vendasDiarias: BASE.vendasDiarias.map((v) => ({
      ...v,
      valor: r(v.valor),
      pedidos: ri(v.pedidos),
    })),
  };
}

/** Provider mockado — implementa o contrato DataProvider. */
export const mockProvider: DataProvider = {
  async listAvailableMonths(): Promise<Month[]> {
    return buildMonths();
  },
  async getDashboard(month?: string): Promise<DashboardData> {
    return dashboardFor(month);
  },
  // Mock não tem crons reais — a página mostra "sem dados".
  async getCronsStatus(): Promise<CronsStatus | null> {
    return null;
  },
};
