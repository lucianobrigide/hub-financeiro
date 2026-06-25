/**
 * Contratos de dados do Hub Financeiro.
 *
 * Estes tipos descrevem TODO o formato de dado que o dashboard consome.
 * Qualquer provider (mock hoje, Supabase amanhã) precisa devolver dados
 * que satisfaçam estas interfaces — é o único contrato entre a fonte de
 * dados e a UI.
 */

/** KPIs da faixa do topo. */
export interface Kpis {
  totalVenda: number;
  totalPedidos: number;
  ticketMedio: number;
}

/** Bloco "Provável" — projeções e percentuais de margem. */
export interface Provavel {
  mediaVendaDiaria: number;
  faturamentoCorrenteProvavel: number;
  mcIdeal: number;
  pontoEquilibrio: number;
  /** % do ponto de equilíbrio já atingido. */
  pontoEquilibrioPct: number;
  retLMedio: number;
  mcLMedia: number;
  mcLUltMes: number;
}

/** Gauge semicircular da Margem de Contribuição Provável. */
export interface MargemGauge {
  valor: number;
  /** Limite superior da escala do gauge (ex.: 214500 = R$ 214,50 Mil). */
  max: number;
}

/** Um ponto da série mensal de Margem de Contribuição (abaixo do gauge). */
export interface McMensalItem {
  valor: number;
  /** Percentual da MC frente ao ideal. */
  pct: number;
}

/** Uma barra/ponto do gráfico "Total Mensal". */
export interface TotalMensalItem {
  /** Rótulo do mês, ex.: "Jun/26". */
  mes: string;
  /** Total da venda no mês, em milhões. */
  venda: number;
  /** % MC sobre a venda. */
  mcVenda: number;
  /** % MC líquida. */
  mcLiquida: number;
}

/** Total de venda agregado por canal/plataforma. */
export interface Plataforma {
  nome: string;
  valor: number;
}

/** Uma linha da sidebar de vendas diárias. */
export interface VendaDiaria {
  /** Data no formato "dd/MM". */
  data: string;
  valor: number;
  pedidos: number;
}

/** Tudo que o dashboard precisa para renderizar, em um único payload. */
export interface DashboardData {
  kpis: Kpis;
  provavel: Provavel;
  margemGauge: MargemGauge;
  mcMensal: McMensalItem[];
  totalMensal: TotalMensalItem[];
  plataformas: Plataforma[];
  vendasDiarias: VendaDiaria[];
}

/**
 * Contrato de qualquer fonte de dados do Hub.
 *
 * `getDashboard` é assíncrono de propósito: o mock resolve na hora, mas o
 * futuro provider do Supabase buscará via Edge Function (rede). Manter a
 * assinatura assíncrona desde já garante que trocar a fonte não exija
 * mudar nenhum componente visual.
 */
export interface DataProvider {
  getDashboard(): Promise<DashboardData>;
}
