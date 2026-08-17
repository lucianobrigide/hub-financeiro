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
  /** Bruta − CMV, exibido quando o canal está "em consolidação" (cobertura < piso):
   *  bruta/CMV são reais desde a venda, mas as deduções ainda aguardam liquidação. */
  margemBruta?: number | null;
  /** Nota da linha M.C. (ex.: "cobertura 17% — em consolidação"). Regra dura:
   *  sem dado real de dedução, mostra-se cobertura, nunca um número estimado. */
  mcNota?: string | null;
}

/** Um dia da série do gráfico diário (Faturamento + M.C. reconciliada). */
export interface SerieDiariaItem {
  /** "DD/MM". */
  data: string;
  faturamento: number;
  mc: number;
  /** Composição de despesas do dia (presente nas séries POR CANAL). Somam c/ a M.C. = faturamento. */
  cmv?: number;
  comissao?: number;
  frete?: number;
  ads?: number;
  /** Custos de ciclo mensal rateados no dia (afiliados/DIFAL/Full/devoluções). */
  outras?: number;
}

/** DRE de um SKU no mês (dentro de um canal). */
export interface SkuDre {
  sku: string;
  titulo: string;
  faturamento: number;
  cmv: number;
  comissao: number;
  frete: number;
  ads: number;
  /** M.C. de PRODUTO = faturamento − CMV − comissão − frete − ADS (antes do overhead do canal). */
  mc: number;
  /** M.C. de produto como % do faturamento. */
  mcPct: number | null;
  /** Série diária do SKU (composição por dia — reusa o gráfico empilhado). */
  serie: SerieDiariaItem[];
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
/** Uma despesa unitária no drill-down de item do DRE. */
export interface DreItem {
  fornecedor: string;
  valor: number;
  /** "DD/MM". */
  data: string;
  doc: string | null;
  /** 'AP' (conta a pagar) | 'CC' (pagamento direto na conta corrente). */
  fonte: string;
}

/* ── Recebíveis (F.C. Projetado) ──────────────────────────────────────────────
 * "Quanto cada plataforma ainda me deve, e em que dia esse dinheiro cai."
 * REGRA DURA: nada estimado. Plataforma sem integração volta `integrado: false`
 * e valores null — a UI diz "aguardando integração", nunca um número inventado.
 */

/** Um dia do cronograma de liberação de uma plataforma. */
export interface RecebivelDia {
  /** 'YYYY-MM-DD' — dia em que o dinheiro é liberado/cai. */
  data: string;
  /** Valor LÍQUIDO a receber nesse dia (R$), já deduzido do que a plataforma retém. */
  valor: number;
}

/** Recebíveis de UMA plataforma. */
export interface RecebiveisPlataforma {
  /** Slug estável, ex.: 'mercado-pago', 'shopee'. */
  id: string;
  nome: string;
  /** De onde o número sai (ex.: "API do Mercado Pago — released/pending"). Texto honesto. */
  fonte: string;
  /** false = ainda sem integração. Valores ficam null; a UI nunca mostra R$ 0 falso. */
  integrado: boolean;
  /** Σ dos dias a liberar. null quando não integrado. */
  total: number | null;
  /** Já liberado e parado na conta da plataforma (ainda não sacado). null = sem dado. */
  disponivel?: number | null;
  /** Cronograma dia a dia. Vazio quando não integrado. */
  dias: RecebivelDia[];
  /** Quando o dado foi coletado ("17/08 03:12"). null = sem coleta ainda. */
  atualizadoEm?: string | null;
  /** Observação exibida no card (ex.: "API em conexão — próxima da fila"). */
  nota?: string | null;
}

/** Payload da seção "Recebíveis por plataforma". */
export interface Recebiveis {
  /** Dia de referência (hoje, BRT) — as faixas (D+7, D+15…) são contadas a partir dele. */
  referencia: string;
  plataformas: RecebiveisPlataforma[];
}

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
  /**
   * DRE por SKU de um canal no mês (para o "Ver mais" → seção por SKU).
   * `canal` = chave curta: 'ml' | 'sp' | 'tt' | 'az' | 'b2b'.
   * OPCIONAL: só o provider Supabase implementa.
   */
  getDreSku?(canal: string, month: string): Promise<SkuDre[]>;
  /**
   * Linhas do DRE preenchíveis pela Omie (Grupo R + C# de fonte Omie) para um mês.
   * Retorna mapa `dre_code -> valor` (ex.: { R1: 6458.35, R3: 261768.89 }).
   * OPCIONAL: só o provider Supabase implementa.
   */
  getDreGrupoR?(month: string): Promise<Record<string, number>>;
  /**
   * Subcategorias (drill-down) das linhas do DRE preenchíveis pela Omie, para um mês.
   * Array de `{ dre_code, nome, valor }` — o DreTable agrupa por dre_code p/ expandir a linha.
   * OPCIONAL: só o provider Supabase implementa.
   */
  getDreGrupoRDetalhe?(month: string): Promise<{ dre_code: string; nome: string; valor: number }[]>;
  /**
   * 3º nível do drill-down: despesas UNITÁRIAS de uma (linha × categoria) no mês.
   * Cada item: fornecedor (nome), valor, data, doc, fonte ('AP' | 'CC').
   * OPCIONAL: só o provider Supabase implementa.
   */
  getDreItens?(month: string, dreCode: string, categoria: string): Promise<DreItem[]>;
  /**
   * Linhas ACIMA da Margem de Contribuição, consolidadas do Hub (todos os canais), no mês.
   * Mapa `label da linha do DRE -> valor` (ex.: { "Receita Bruta": …, "CMV": … }).
   * OPCIONAL: só o provider Supabase implementa.
   */
  getDreTopo?(month: string): Promise<Record<string, number>>;
  /**
   * Trava de fechamento: compara o DRE vivo do mês com o snapshot congelado no
   * fechamento oficial (omie_dre_drift). OPCIONAL: só o provider Supabase implementa.
   */
  getDreDrift?(month: string): Promise<DreDrift | null>;
  /**
   * Recebíveis por plataforma (aba F.C. Projetado): quanto cada canal ainda deve
   * e em que dia libera. `null` => provider sem suporte (a UI mostra "sem dados").
   * OPCIONAL: providers antigos não implementam.
   */
  getRecebiveis?(): Promise<Recebiveis | null>;
}

/** Resultado da trava de fechamento (RPC omie_dre_drift). */
export interface DreDrift {
  mes: string;
  /** false = mês nunca foi fechado (sem snapshot). */
  fechado: boolean;
  /** "DD/MM/YYYY HH:MM" do fechamento oficial. */
  fechado_em?: string;
  obs?: string | null;
  /** Soma dos deltas (0 = vivo idêntico ao fechado). */
  drift_total?: number;
  linhas_divergentes?: { linha: string; fechado: number; atual: number; delta: number }[];
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
  /** Falhas no pg_cron nas últimas 24h (mesmo que o último run tenha sido ok). */
  falhas_24h?: number;
  /** Última falha nas 24h: "05/08 03:30 — mensagem" ou null. */
  ultima_falha?: string | null;
  /** Se o último run falhou mas o log de dados registrou sucesso depois
   *  (ex.: re-execução manual): "05/08 10:54" ou null. */
  recuperado_em?: string | null;
}

/** Payload da página de Crons. */
export interface CronsStatus {
  gerado_em: string;
  total: number;
  verdes: number;
  amarelos: number;
  vermelhos: number;
  /** Total de falhas no pg_cron nas últimas 24h (todas as automações). */
  falhas_24h?: number;
  crons: CronInfo[];
}
