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
  /** Soma das M.C. de todos os canais. null se nenhum canal tem M.C. calculada. */
  mcTotal: number | null;
}

/** Metas do mês (planejamento). */
export interface Meta {
  /** Meta de Margem de Contribuição do mês (R$). null = sem meta definida. */
  mcMeta: number | null;
}

/** Bloco "Provável" — projeções e percentuais de margem. */
export interface Provavel {
  mediaVendaDiaria: number;
  faturamentoCorrenteProvavel: number;
  // Campos de margem: null quando não há dado (sem custo/tarifa). Nunca 0 falso.
  mcIdeal: number | null;
  pontoEquilibrio: number | null;
  /** % do ponto de equilíbrio já atingido. */
  pontoEquilibrioPct: number | null;
  retLMedio: number | null;
  mcLMedia: number | null;
  mcLUltMes: number | null;
}

/** Gauge semicircular da Margem de Contribuição Provável. */
export interface MargemGauge {
  /** null = sem dado de margem (não temos custo). */
  valor: number | null;
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
  /** % MC sobre a venda. null = sem dado de margem. */
  mcVenda: number | null;
  /** % MC líquida. null = sem dado de margem. */
  mcLiquida: number | null;
}

/** Total de venda agregado por canal/plataforma. */
export interface Plataforma {
  nome: string;
  /** null = canal sem integração/dado ainda (ex.: Shopee/TikTok/Amazon). */
  valor: number | null;
}

/** Uma linha de dedução do mini-DRE (label + valor). */
export interface DreLinha {
  label: string;
  /** null = sem dado real ainda (ex.: RPC de margem travado). Nunca 0 falso. */
  valor: number | null;
  /** Indicador opcional (ex.: "3 de 7 confirmados"). */
  nota?: string;
}

/**
 * Mini-demonstrativo (DRE) de uma plataforma, exibido no card.
 * Topo (bruto/cancel/líquido) pode ser REAL; deduções e M.C. ficam null
 * enquanto o RPC de margem estiver travado. null => UI mostra "sem dados".
 */
export interface PlataformaDre {
  nome: string;
  faturamentoBruto: number | null;
  cancelDevolucoes: number | null;
  faturamentoLiquido: number | null;
  /** Comissão, Frete, ADS, Full, Afiliados, CMV — nesta ordem. */
  deducoes: DreLinha[];
  /** Margem de Contribuição = líquido − Σ(deduções). null se faltar dedução. */
  mc: number | null;
}

/** Um dia da série do gráfico diário (Faturamento + M.C. reconciliada). */
export interface SerieDiariaItem {
  /** "DD/MM". */
  data: string;
  faturamento: number;
  mc: number;
}

/** Uma linha da sidebar de vendas diárias. */
export interface VendaDiaria {
  /** Data no formato "dd/MM". */
  data: string;
  valor: number;
  pedidos: number;
}

/** Dashboard isolado de um canal (mesma estrutura do principal, só o canal). */
export interface CanalDetalhe {
  /** Slug da rota, ex.: "mercado-livre". */
  id: string;
  nome: string;
  kpis: Kpis;
  meta: Meta;
  provavel: Provavel;
  serieDiaria: SerieDiariaItem[];
  /** Mini-DRE do canal (mesmo card do principal). */
  dre: PlataformaDre;
}

/** Tudo que o dashboard precisa para renderizar, em um único payload. */
export interface DashboardData {
  kpis: Kpis;
  meta: Meta;
  provavel: Provavel;
  margemGauge: MargemGauge;
  mcMensal: McMensalItem[];
  totalMensal: TotalMensalItem[];
  plataformas: Plataforma[];
  /** Mini-DRE por plataforma (card de faturamento → M.C.). */
  plataformasDre: PlataformaDre[];
  /** Série diária do mês (todos os canais): Faturamento e M.C. por dia. */
  serieDiaria: SerieDiariaItem[];
  /** Dashboard isolado de cada canal (para o "Ver mais"). */
  porCanal: CanalDetalhe[];
  vendasDiarias: VendaDiaria[];
}

/** Um mês selecionável no dashboard. */
export interface Month {
  /** Identificador no formato 'YYYY-MM', ex.: '2026-06'. */
  value: string;
  /** Rótulo amigável, ex.: 'Junho 2026'. */
  label: string;
}

/**
 * Contrato de qualquer fonte de dados do Hub.
 *
 * Assíncrono de propósito: o mock resolve na hora, mas uma fonte real busca
 * via rede. Manter a assinatura assíncrona garante que trocar a fonte não
 * exija mudar nenhum componente visual.
 */
export interface DataProvider {
  /**
   * Lista os meses disponíveis (mais recente primeiro).
   * OPCIONAL: providers que ainda não suportam seleção de mês (ex.: o provider
   * Supabase/ML atual, que só busca o mês corrente) podem omitir — a UI faz
   * fallback. Opcional também para não quebrar quem implementa só getDashboard.
   */
  listAvailableMonths?(): Promise<Month[]>;
  /**
   * Dados do dashboard para um mês ('YYYY-MM'). Sem `month` => mês corrente.
   * `month` é opcional para manter compatíveis providers que ignoram o filtro.
   */
  getDashboard(month?: string): Promise<DashboardData>;
  /**
   * Estado de saúde de todos os cron jobs que alimentam o dashboard.
   * OPCIONAL: só o provider Supabase tem crons reais. `null` => sem dado.
   */
  getCronsStatus?(): Promise<CronsStatus | null>;
}

/** Um cron job na página de Crons. */
export interface CronInfo {
  jobname: string;
  plataforma: string;
  /** 'diario' | 'semanal' | 'token'. */
  categoria: string;
  /** Horário em linguagem humana ("Todo dia às 03:00 BRT"). */
  horario: string;
  /** O que o cron faz, em linguagem de negócio. */
  o_que_faz: string;
  ativo: boolean;
  /** Confiabilidade do log de aplicação: 'honesto' | 'parcial' | 'suspeito'. */
  confiab_log: string;
  /** Semáforo (vem do pg_cron): 'verde' | 'amarelo' | 'vermelho'. */
  semaforo: string;
  /** Status do último disparo no pg_cron: 'succeeded' | 'failed' | null. */
  pg_status: string | null;
  /** true = a data vem do log de dados (o agendador já não guarda esse run). */
  via_log?: boolean;
  /** Última execução ("16/07 03:00") ou null se sem histórico recente. */
  ultima_exec: string | null;
  horas_atras: number | null;
  duracao_seg: number | null;
}

/** Payload da página de Crons. */
export interface CronsStatus {
  gerado_em: string;
  total: number;
  verdes: number;
  amarelos: number;
  vermelhos: number;
  crons: CronInfo[];
}
