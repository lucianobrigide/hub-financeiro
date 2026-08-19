import "server-only";

import type { CronsStatus, DashboardData, DataProvider, DreDrift, DreItem, Month, PlataformaDre, Recebiveis, SerieDiariaItem, SkuDre, VendaDiaria } from "./types";
import { hojeBrt, recebiveisVazios } from "./recebiveis";

/** Labels das 6 deduções do mini-DRE, na ordem do card. */
const DEDUCAO_LABELS = ["Comissão", "Frete", "ADS", "Full", "Afiliados", "CMV"];
/**
 * ML: DIFAL (ICMS interestadual) + "Custo Devoluções" (fricção da fatura — análogo à Shopee:
 * tarifas de devolução/inconformidade menos as bonificações espelho, líquido).
 */
const DEDUCAO_LABELS_DIFAL = ["Comissão", "Frete", "ADS", "Full", "Afiliados", "DIFAL", "CMV", "Custo Devoluções"];
const DEDUCAO_LABELS_SHOPEE = ["Comissão e Fretes reais cobrados", "ADS", "Full", "Afiliados", "DIFAL", "CMV", "Custo Devoluções"];
/** TikTok: "Taxas" é linha própria (sfp_service_fee + fee_per_item); sem "Full". */
const DEDUCAO_LABELS_TT = ["Comissão", "Taxas", "Frete", "ADS", "Afiliados", "CMV"];
/** SHEIN: bruta = preço PAGO pelo cliente (sellerCurrencyDiscountPrice; decisão do
 *  Luciano 09/08/2026 — bate com a central de vendedores). Deduções REAIS por item;
 *  "Subsídio SHEIN" é CRÉDITO (negativo): a SHEIN calcula o repasse sobre base maior
 *  que o preço pago. Identidade: pago − (comissão + taxa − subsídio) =
 *  estimatedGrossIncome da API, centavo a centavo. Settlement é fase futura. */
const DEDUCAO_LABELS_SHEIN = ["Comissão", "Taxa de serviço", "Subsídio SHEIN", "CMV"];
/** Magalu (MVP 17/08/2026): bruta = total PAGO pelo cliente (amounts.total já é pós-desconto;
 *  o desconto NÃO é dedução — entrar seria dupla contagem). Comissão e frete REAIS do pedido
 *  (/seller/v1/orders). Repasse/settlement (Análise Financeira) é fase futura. */
const DEDUCAO_LABELS_MAGALU = ["Comissão", "Frete", "CMV"];

/** DRE de uma plataforma sem dado (tudo null) — UI mostra "sem dados". */
function dreVazio(nome: string): PlataformaDre {
  return {
    nome,
    faturamentoBruto: null,
    cancelDevolucoes: null,
    faturamentoLiquido: null,
    deducoes: DEDUCAO_LABELS.map((label) => ({ label, valor: null })),
    mc: null,
  };
}

/**
 * Provider de dados REAIS — lê das TABELAS do Supabase (ml_pedidos etc.) via RPCs
 * SECURITY DEFINER (`ml_dashboard_months`, `ml_dashboard`), NÃO da API do ML.
 *
 * Roda SÓ no servidor (import "server-only"). Usa o service_role apenas para
 * chamar os RPCs (que furam a RLS por serem SECURITY DEFINER) — nunca exposto
 * ao client.
 *
 * REGRA DE OURO: nenhum número falso. Campos sem dado real (margem, outros
 * canais, canceladas/devolvidas) voltam como `null` — a UI mostra "sem dados".
 */

const SUPABASE_URL =
  process.env.SUPABASE_URL ?? "https://klwczmapuupensozxbsr.supabase.co";

// Metas de Margem de Contribuição por mês (R$). Ajustável conforme o planejamento.
// Meses sem entrada usam META_MC_DEFAULT.
const META_MC: Record<string, number> = {
  "2026-06": 220000,
  "2026-07": 220000,
};
const META_MC_DEFAULT = 220000;

// Metas de M.C. por CANAL (R$), por slug de rota. Vazio = sem meta por canal ainda.
const META_MC_CANAL: Record<string, number> = {};

// Metadados dos canais: slug de rota, nome (bate com plataformasDre) e chave da série.
const CANAIS = [
  { id: "mercado-livre", nome: "Mercado Livre", key: "ml" },
  { id: "shopee", nome: "Shopee", key: "sp" },
  { id: "tiktok", nome: "TikTok Shop", key: "tt" },
  { id: "amazon", nome: "Amazon", key: "az" },
  { id: "shein", nome: "SHEIN", key: "sh" },
  { id: "magalu", nome: "Magalu", key: "mg" },
  { id: "vendas-internas", nome: "B2B", key: "b2b" },
] as const;

const MESES_FULL = [
  "Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho",
  "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro",
];

function labelMes(value: string): string {
  // value = 'YYYY-MM'
  const [y, m] = value.split("-").map(Number);
  return `${MESES_FULL[(m ?? 1) - 1]} ${y}`;
}
function labelMesCurto(value: string): string {
  const [y, m] = value.split("-").map(Number);
  const curto = ["Jan", "Fev", "Mar", "Abr", "Mai", "Jun", "Jul", "Ago", "Set", "Out", "Nov", "Dez"];
  return `${curto[(m ?? 1) - 1]}/${String(y % 100).padStart(2, "0")}`;
}

function requireKey(): string {
  const k = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!k) throw new Error("SUPABASE_SERVICE_ROLE_KEY ausente (necessário p/ DATA_SOURCE=supabase)");
  return k;
}

async function rpc<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const key = requireKey();
  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
    cache: "no-store", // sempre dado fresco; mantém a rota dinâmica
  });
  if (!resp.ok) {
    throw new Error(`RPC ${fn} respondeu HTTP ${resp.status}`);
  }
  return (await resp.json()) as T;
}

/** Retorno do RPC `mp_recebiveis` (cronograma de liberação do Mercado Pago). */
interface MpRecebiveisRow {
  /** 'YYYY-MM-DD' (hoje, BRT). */
  referencia: string;
  /** Σ do líquido a liberar de hoje em diante. */
  total: number;
  /** Quantos pagamentos compõem o total. */
  pagamentos: number;
  /** Pagamentos sem `net_received_amount` na API — ficam FORA do total (nada estimado). */
  sem_liquido: number;
  /** ISO da última ingestão. */
  atualizado_em: string | null;
  dias: { data: string; valor: number }[];
}

/**
 * Retorno do RPC `shopee_recebiveis`. Cronograma PARCIAL com data DERIVADA
 * (decisão do Luciano 19/08/2026, exceção à REGRA DURA): o VALOR é 100% real
 * (escrow da API); a DATA vem de dois fatos da própria Shopee — entrega real
 * (tracking) + regra da Garantia (escrow libera quando o pedido conclui, teto
 * = entrega + 7~8d, medido em 14.434 pedidos). Só pedido ENTREGUE ganha data
 * (entrega + 8d, o teto); em trânsito/pré-envio vai em `sem_data`.
 */
interface ShopeeRecebiveisRow {
  referencia: string;
  /** Σ do escrow ainda não creditado na carteira (já sem devoluções/compensados). */
  total: number;
  pedidos: number;
  /** Escrow que NÃO vai cair: devolução, compensado por fora, ou fechado como débito. */
  em_disputa: number;
  pedidos_disputa: number;
  /** Saldo parado na carteira Shopee (current_balance da última transação). */
  disponivel: number | null;
  /** Janela coberta pela ingestão da carteira — fora dela o pedido é desconhecido, não "a receber". */
  cobertura_de: string | null;
  cobertura_ate: string | null;
  atualizado_em: string | null;
  /** Cronograma (Camada A): concluído → hoje; entregue → entrega real + 8d. */
  dias: { data: string; valor: number }[];
  com_data: number;
  pedidos_com_data: number;
  /** Em trânsito/pré-envio: valor real, sem data (ganha data quando entregar). */
  sem_data: number;
  pedidos_sem_data: number;
  /** Detector de drift (Fase 3): false = acurácia 30d < 80% → o RPC já devolve dias=[] e tudo em sem_data. */
  cronograma_ativo: boolean;
  /** Fração do VALOR creditado (30d) que caiu até a data prevista +1d. null = base insuficiente. */
  acuracia_30d: number | null;
  base_acuracia: number;
}

/**
 * Retorno do RPC `tt_recebiveis`. `total` é o BRUTO pago pelo cliente em pedidos
 * ainda não liquidados — informativo, não caixa líquido (ver `foraDoTotal`).
 */
interface TtRecebiveisRow {
  referencia: string;
  total: number;
  pedidos: number;
  mais_antigo: string | null;
  /** Faixa do repasse realizado (settlement/pago) por mês, em %. */
  repasse_min: number | null;
  repasse_max: number | null;
  meses_base: number;
  atualizado_em: string | null;
}

/**
 * Retorno do RPC `az_recebiveis`. Cronograma PARCIAL: `dias` cobre só o que já
 * está a caminho do banco; `sem_data` é o ciclo aberto (real, mas sem data).
 */
interface AzRecebiveisRow {
  referencia: string;
  total: number;
  em_transito: number;
  sem_data: number;
  grupos_abertos: number;
  atualizado_em: string | null;
  dias: { data: string; valor: number }[];
}

/**
 * Retorno do RPC `shein_recebiveis`. Cronograma PARCIAL: `dias` vem do
 * `estimate_pay_time` do check order; `sem_data` são os pedidos que ainda não
 * geraram check order (valor real, sem data).
 */
interface SheinRecebiveisRow {
  referencia: string;
  total: number;
  com_data: number;
  sem_data: number;
  pedidos_sem_data: number;
  mais_antigo: string | null;
  atualizado_em: string | null;
  dias: { data: string; valor: number }[];
}

/** Retorno do RPC `magalu_recebiveis`. Sem cronograma: o Magalu não publica data de repasse. */
interface MagaluRecebiveisRow {
  referencia: string;
  total: number;
  pedidos: number;
  mais_antigo: string | null;
  atualizado_em: string | null;
}

/** "84,6%" — percentual no formato BR para as notas dos cards. */
function pctBr(v: number): string {
  return `${v.toLocaleString("pt-BR", { maximumFractionDigits: 1 })}%`;
}

/** "R$ 14.706,17" — para notas de texto montadas no servidor. */
function brlSimples(v: number): string {
  return v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
}

/** "17/08" a partir de 'YYYY-MM-DD'. */
function fmtDia(d: string): string {
  const [, m, dia] = d.split("-");
  return `${dia}/${m}`;
}

/** "17/08 15:27" (BRT) a partir de um ISO — usado no "atualizado" dos cards. */
function fmtDataHora(iso: string): string {
  return new Date(iso).toLocaleString("pt-BR", {
    timeZone: "America/Sao_Paulo",
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** Uma linha do RPC ml_dre_diario (faturamento válido + custos DIRETOS do dia). */
interface DreDiaRow {
  data: string;
  fat: number;
  pedidos: number;
  cmv: number;
  comissao: number;
  frete: number;
  ads: number;
}

/** Uma linha do RPC dre_diario_canais (faturamento + custos diretos/dia por canal, exceto ML). */
interface CanalDiaRow {
  canal: string; // 'sp' | 'tt' | 'az' | 'b2b' | 'sh'
  data: string; // 'DD/MM'
  fat: number;
  cmv: number;
  comissao: number;
  frete: number;
  ads: number;
  /** Crédito da plataforma, POSITIVO no RPC (só SHEIN ≠ 0). Abate as deduções do dia. */
  subsidio: number;
}

interface AggReal {
  totalVenda: number;
  totalPedidos: number;
  totalPedidosValidos: number; // paid + partially_refunded (sem cancelados)
  diasComVenda: number;
  diasNoMes: number;
  vendasDiarias: VendaDiaria[];
}

/** Retorno do RPC ml_faturamento_ml (3 linhas de topo do mini-DRE do card ML). */
interface FatMl {
  faturamentoBruto: number;
  cancelDevolucoes: number;
  faturamentoLiquido: number;
}

/** Retorno do RPC ml_comissao (comissão líquida do mês, régua paid+partial). */
interface ComissaoMl {
  comissao_total_mes: number;
}

/**
 * Retorno do RPC ml_ads. `ads_total_mes` é LÍQUIDO: o gasto vem BRUTO da API de delivery
 * e o ML bonifica parte na fatura (BPAD) — crédito que a reconstrução ignorava.
 */
interface AdsMl {
  ads_total_mes: number;   // = ads_bruto − ads_bonificacao
  ads_bruto: number;
  ads_bonificacao: number;
}

/**
 * Retorno do RPC ml_friccao: custo de devoluções/fricção da fatura ML, LÍQUIDO
 * (débitos CXDED/CDSDB/CFPB/CXDID − bonificações espelho BXDED/BDSDB/BXDID).
 * Análogo ao "Custo Devoluções" da Shopee.
 */
interface FriccaoMl {
  friccao_total: number;
  debitos: number;
  creditos: number;
  lancamentos: number;
}

/** Retorno do RPC ml_frete (custo de envio do vendedor no mês, régua paid+partial). */
interface FreteMl {
  frete_total_mes: number;
}

/** Retorno do RPC ml_full (custo de Fulfillment do mês: armazenamento/coleta/penalidade). */
interface FullMl {
  full_total_mes: number;
}

/** Retorno do RPC sp_afiliados_ml (custo do programa de afiliados CVAF, régua creation_date). */
interface AfiliadosMl {
  afiliados_total_mes: number;
}

/** Retorno do RPC sp_difal_ml (ICMS-DIFAL interestadual CDIFAL, régua creation_date). */
interface DifalMl {
  difal_total_mes: number;
}

/** Retorno do RPC ml_cmv (custo da mercadoria vendida no mês, régua paid+partial). */
interface CmvMl {
  cmv_total_mes: number;
}

/** Retorno do RPC az_faturamento (bruta Amazon do mês, régua Shipped+Unshipped). */
interface FatAz {
  faturamento_bruto: number;
  total_pedidos: number;
}

/** Retorno do RPC az_deducoes (settlement: Easy Ship, refund). */
interface DedAz {
  comissao: number;
  easy_ship: number;
  refund: number;
  pedidos_com_comissao: number;
  pedidos_total: number;
}

/** Retorno do RPC az_comissao (híbrida: real onde confirmado, estimada onde não). */
interface ComissaoAz {
  comissao_total: number;
  pedidos_confirmados: number;
  pedidos_total: number;
}

/** Retorno do RPC az_frete_mes (híbrido: real onde confirmado, estimado onde não). */
interface FreteAz {
  frete_total: number;
  pedidos_confirmados: number;
  pedidos_total: number;
}

/** Retorno do RPC az_cmv (custo × quantidade dos itens vendidos). */
interface CmvAz {
  cmv_total: number;
  itens_com_custo: number;
  itens_total: number;
}

/** Retorno do RPC shein_faturamento (bruta = Σ preço PAGO pelo cliente, status ≠ 6/8/9; competência payment_time BRT). */
interface FatShein {
  faturamento_bruto: number;
  cancel_devolucoes: number;
  total_pedidos: number;
}

/** Retorno do RPC shein_deducoes (comissão, taxa de fulfillment e subsídio SHEIN — crédito — REAIS por item). */
interface DedShein {
  comissao: number;
  taxa_servico: number;
  subsidio: number;
}

/** Retorno do RPC shein_cmv (custo × quantidade, via ml_custo_produto com vigência). */
interface CmvShein {
  cmv_total: number;
  itens_com_custo: number;
  itens_total: number;
}

/** Retorno do RPC magalu_faturamento (bruta = Σ amounts.total PAGO pelo cliente, status ≠ cancelled; competência created_at BRT). */
interface FatMg {
  faturamento_bruto: number;
  total_pedidos: number;
}

/** Retorno do RPC magalu_deducoes (comissão e frete REAIS do pedido; desconto é informativo — já embutido na bruta). */
interface DedMg {
  comissao: number;
  frete: number;
  desconto: number;
}

/** Retorno do RPC magalu_cmv (custo × quantidade, via ml_custo_produto com vigência). */
interface CmvMg {
  cmv_total: number;
  itens_com_custo: number;
  itens_total: number;
}

/**
 * Retorno do RPC azads_ads (gasto Amazon Ads do mês, Reports v3 por campanha).
 * Validado 03/08/2026: julho pela API = painel centavo a centavo (R$ 14.125,85).
 * `cost` vem sem os impostos que a fatura da Amazon destaca por lei.
 */
interface AdsAzads {
  ads_total_mes: number;
  dias_com_dado: number;
  ultima_atualizacao: string | null;
}

/** Retorno do RPC sp_faturamento (bruta Shopee do mês, régua COMPLETED). */
interface FatSp {
  faturamento_bruto: number;
  total_pedidos: number;
}

/** Retorno do RPC sp_custo_devolucoes (estorno das devoluções finalizadas Shopee). */
interface CustoDevSp {
  custo_total: number;
  pedidos_devolvidos: number;
  receita_devolvida: number;
}

/**
 * Retorno do RPC sp_repasse: repasse real (escrow) que caiu na conta. É a base
 * da linha "Comissão e Fretes reais cobrados" (= bruta − repasse − afiliados):
 * o escrow já consolida os créditos que a decomposição bruta ignora — subsídio
 * de frete, reembolso de voucher, ajustes PIX.
 */
interface RepasseSp {
  repasse_total: number;
  pedidos_total: number;
  pedidos_com_repasse: number;
  pedidos_zero: number;
  pedidos_neg: number;
  /** Subconjunto com escrow (escrow_adjusted preenchido): bruta e repasse do mesmo
   *  conjunto, p/ a cobertura do piso e a M.C. acima dele fecharem dos dois lados. */
  bruta_com_escrow: number;
  repasse_com_escrow: number;
}

/** Retorno do RPC sp_cmv (CMV Shopee via ml_custo_produto + unaccent). */
interface CmvSp {
  cmv_total: number;
  /** CMV do subconjunto com escrow (p/ a M.C. acima do piso fechar dos dois lados). */
  cmv_com_escrow: number;
  itens_com_custo: number;
  itens_total: number;
}

/** Retorno do RPC sp_afiliados (AMS Shopee do mês, campo separado no escrow). */
interface AfiliSp {
  afiliados_total: number;
  pedidos_com_ams: number;
  pedidos_total: number;
}

/** Retorno do RPC shopee_ads (gasto CPC diário do mês; escopo Ads já no token). */
interface AdsSp {
  ads_total_mes: number;
}

/** Retorno do RPC shopee_difal (ICMS-DIFAL da carteira, ADJUSTMENT_CENTER_DEDUCT). */
interface DifalSp {
  difal_total_mes: number;
}

/** Retorno do RPC b2b_faturamento (bruta B2B do mês, NFs por data_emissao). */
interface FatB2b {
  faturamento_bruto: number;
  total_notas: number;
}

/** Retorno do RPC b2b_cmv (CMV B2B via ml_custo_produto). */
interface CmvB2b {
  cmv_total: number;
  itens_com_custo: number;
  itens_total: number;
}

/** Retorno do RPC tt_faturamento. Bruta = gross antes da devolução; líquido = revenue_amount
 *  (base da M.C.); devoluções = refund líquido explícito (refund_subtotal + seller_discount_refund). */
interface FatTt {
  faturamento_bruto: number;
  devolucoes: number;
  faturamento_liquido: number;
  /** Receita SÓ do subconjunto liquidado (base da M.C. acima do piso). */
  liquido_liquidado: number;
  total_pedidos: number;
  pedidos_liquidados: number;
  /** Cobertura ponderada por receita = pago_liquidado / pago_total. */
  pago_total: number;
  pago_liquidado: number;
  settlement: number;
}

/** Retorno do RPC tt_deducoes_projetado (real dos liquidados + provisão dos aguardando
 *  settlement, por take-rate móvel; afiliado usa aff_commission real quando houver;
 *  ads prioriza tt_ads_diario). Decisão do Luciano 12/08/2026: M.C. projetada em vez
 *  de esconder abaixo do piso — a provisão é substituída pelo real pedido a pedido. */
interface DedTt {
  comissao: number;
  taxas: number;
  frete: number;
  ads: number;
  afiliados: number;
  pedidos: number;
  pedidos_liquidados: number;
  pedidos_provisionados: number;
  pedidos_afiliado_real: number;
  /** Cobertura ponderada por receita (0–100). */
  pct_liquidado: number;
  ads_fonte: "tt_ads_diario" | "settlement+provisao";
}

/** Retorno do RPC tt_cmv (CMV TikTok via ml_custo_produto + unaccent no seller_sku). */
interface CmvTt {
  cmv_total: number;
  /** CMV SÓ do subconjunto liquidado (p/ a M.C. acima do piso fechar dos dois lados). */
  cmv_liquidado: number;
  itens_com_custo: number;
  itens_total: number;
  itens_liquidados: number;
}

// Piso de cobertura (ponderada por receita) abaixo do qual NÃO se exibe M.C.: o card
// mostra bruta/CMV/margem bruta reais e "em consolidação" no lugar de um número inventado.
// 80% é valor INICIAL por julgamento (não calibrado) — revisar após um ciclo com variância
// medida. Uma régua só, TikTok e Shopee. Ver CLAUDE.md (Convenções › piso de cobertura).
const PISO_COBERTURA = 0.80;

export const supabaseProvider: DataProvider = {
  async listAvailableMonths(): Promise<Month[]> {
    // Só os meses que EXISTEM nas tabelas (hoje: junho/2026).
    const months = await rpc<string[]>("ml_dashboard_months");
    return (months ?? []).map((value) => ({ value, label: labelMes(value) }));
  },

  // Saúde dos crons: o semáforo vem do pg_cron (cron.job_run_details), o detalhe do log
  // de aplicação. O front nunca toca no schema cron.* — só consome esta RPC.
  async getCronsStatus(): Promise<CronsStatus | null> {
    return rpc<CronsStatus>("crons_status");
  },

  // Linhas do DRE preenchíveis pela Omie (Grupo R + C# de fonte Omie) no mês.
  // Mapa dre_code -> valor; o DreTable casa pelo campo `code` de cada linha.
  async getDreGrupoR(month: string): Promise<Record<string, number>> {
    return (await rpc<Record<string, number>>("omie_dre_grupo_r", { p_month: month })) ?? {};
  },

  // Subcategorias (drill-down) de cada linha do DRE (Omie) no mês, para expandir ao clicar.
  async getDreGrupoRDetalhe(month: string): Promise<{ dre_code: string; nome: string; valor: number }[]> {
    return (await rpc<{ dre_code: string; nome: string; valor: number }[]>("omie_dre_grupo_r_detalhe", { p_month: month })) ?? [];
  },

  // 3º nível: despesas unitárias de uma (linha × categoria) no mês.
  async getDreItens(month: string, dreCode: string, categoria: string): Promise<DreItem[]> {
    return (await rpc<DreItem[]>("omie_dre_itens", { p_month: month, p_dre_code: dreCode, p_categoria: categoria })) ?? [];
  },

  // Trava de fechamento: vivo × snapshot congelado do mês (omie_dre_drift).
  async getDreDrift(month: string): Promise<DreDrift | null> {
    return (await rpc<DreDrift>("omie_dre_drift", { p_month: month })) ?? null;
  },

  /**
   * Recebíveis por plataforma (F.C. Projetado).
   *
   * INTEGRADO (17/08/2026): **Mercado Pago** — RPC `mp_recebiveis` (tabela
   * `mp_pagamentos`, ingestão `mp_fill_recebiveis`). Valor = líquido REAL que
   * cai na conta (`net_received_amount`, já sem comissão ML/frete/taxa MP/cupom),
   * agregado por `money_release_date`. Nada estimado.
   *
   * As demais plataformas seguem "aguardando integração" — para ligar cada uma,
   * preencher `total`/`disponivel`/`dias` e virar `integrado: true`. A UI não muda.
   */
  async getRecebiveis(): Promise<Recebiveis> {
    const plataformas = recebiveisVazios();
    const referencia = hojeBrt();

    // Mercado Pago. Falha de RPC não derruba a página: o canal segue "sem dados".
    try {
      const mp = await rpc<MpRecebiveisRow>("mp_recebiveis");
      const i = plataformas.findIndex((p) => p.id === "mercado-pago");
      if (mp && i >= 0) {
        // Cobertura honesta: pagamento sem líquido na API não é estimado — fica de
        // fora do total e vira nota no card, nunca um número inventado.
        const nota =
          mp.sem_liquido > 0
            ? `${mp.pagamentos} pagamentos a liberar · ${mp.sem_liquido} ainda sem valor líquido na API (fora do total)`
            : `${mp.pagamentos} pagamentos a liberar — líquido real da API, sem estimativa`;
        plataformas[i] = {
          ...plataformas[i],
          integrado: true,
          total: mp.total,
          // Saldo já liberado na conta MP: endpoint de balance responde 403 para
          // esta credencial (ver CLAUDE.md/Pendências) — sem dado, não inventa.
          disponivel: null,
          dias: (mp.dias ?? []).map((d) => ({ data: d.data, valor: d.valor })),
          atualizadoEm: mp.atualizado_em ? fmtDataHora(mp.atualizado_em) : null,
          nota,
        };
      }
    } catch {
      // mantém o card como "aguardando integração"
    }

    // Shopee. Cronograma PARCIAL com data DERIVADA (decisão do Luciano 19/08/2026):
    // valores 100% reais (escrow da API); a data vem de fatos da própria Shopee —
    // pedido ENTREGUE (tracking) → entrega + 8d (teto da conclusão automática,
    // 2/3 caem antes); concluído → hoje. Em trânsito/pré-envio = valor real SEM
    // data (`valorSemData`, estilo Amazon) — vira "com data" quando entrega.
    // Detector de drift no RPC: acurácia 30d < 80% suspende o cronograma sozinho.
    try {
      const sp = await rpc<ShopeeRecebiveisRow>("shopee_recebiveis");
      const i = plataformas.findIndex((p) => p.id === "shopee");
      if (sp && i >= 0) {
        const partes: string[] = [];
        if (sp.cronograma_ativo && sp.pedidos_com_data > 0) {
          partes.push(
            `${brlSimples(sp.com_data)} com data derivada — entrega real + 8d, o teto da conclusão automática da Shopee (2/3 caem antes)`,
          );
          if (sp.acuracia_30d != null) {
            partes.push(
              `acurácia 30d: ${Math.round(sp.acuracia_30d * 100)}% do valor liberado até a data prevista (${sp.base_acuracia} pedidos)`,
            );
          }
        } else if (!sp.cronograma_ativo) {
          // O detector reprovou: melhor sem cronograma do que com data furada.
          partes.push(
            `cronograma suspenso pelo detector de acurácia (30d: ${sp.acuracia_30d != null ? Math.round(sp.acuracia_30d * 100) : "?"}% < piso de 80%) — só o total`,
          );
        }
        if (sp.sem_data > 0) {
          partes.push(
            `${brlSimples(sp.sem_data)} em ${sp.pedidos_sem_data} pedidos em trânsito/pré-envio, sem data ainda (ganham data quando entregar)`,
          );
        }
        // Devolução/compensado/escrow fechado como débito não entra no total — mas
        // aparece, pra a exclusão ser auditável em vez de sumir em silêncio.
        if (sp.em_disputa > 0) {
          partes.push(
            `fora do total: ${brlSimples(sp.em_disputa)} em ${sp.pedidos_disputa} pedidos de devolução/ajuste, que não vão cair`,
          );
        }
        plataformas[i] = {
          ...plataformas[i],
          integrado: true,
          total: sp.total,
          disponivel: sp.disponivel,
          valorSemData: sp.sem_data !== 0 ? sp.sem_data : null,
          dias: (sp.dias ?? []).map((d) => ({ data: d.data, valor: d.valor })),
          atualizadoEm: sp.atualizado_em ? fmtDataHora(sp.atualizado_em) : null,
          nota: partes.join(" · "),
        };
      }
    } catch {
      // mantém o card como "aguardando integração"
    }

    // Amazon. Cronograma PARCIAL: o que já está a caminho do banco tem data de
    // transferência (grupos Closed+Processing); o ciclo corrente (Open) é valor
    // real mas a Amazon não publica quando fecha — vai em `valorSemData`.
    try {
      const az = await rpc<AzRecebiveisRow>("az_recebiveis");
      const i = plataformas.findIndex((p) => p.id === "amazon");
      if (az && i >= 0) {
        const partes = [`${brlSimples(az.em_transito)} já a caminho do banco`];
        if (az.grupos_abertos > 0) {
          partes.push(
            `${brlSimples(az.sem_data)} no ciclo aberto (a Amazon não publica a data de fechamento)`,
          );
        }
        plataformas[i] = {
          ...plataformas[i],
          integrado: true,
          total: az.total,
          disponivel: null,
          valorSemData: az.sem_data !== 0 ? az.sem_data : null,
          dias: (az.dias ?? []).map((d) => ({ data: d.data, valor: d.valor })),
          atualizadoEm: az.atualizado_em ? fmtDataHora(az.atualizado_em) : null,
          nota: partes.join(" · "),
        };
      }
    } catch {
      // mantém o card como "aguardando integração"
    }

    // SHEIN. Cronograma PARCIAL, como a Amazon, mas por outro motivo: o check
    // order traz `estimate_pay_time` (data que a própria SHEIN estima), só que
    // ele nasce ~2 semanas após a venda. Pedido novo tem valor real e ainda não
    // tem data — vai em `valorSemData`.
    try {
      const sh = await rpc<SheinRecebiveisRow>("shein_recebiveis");
      const i = plataformas.findIndex((p) => p.id === "shein");
      if (sh && i >= 0) {
        const partes = [
          `${brlSimples(sh.com_data)} com data estimada pela SHEIN (check order emitido)`,
        ];
        if (sh.pedidos_sem_data > 0) {
          partes.push(
            `${brlSimples(sh.sem_data)} em ${sh.pedidos_sem_data} pedidos que ainda não geraram check order${sh.mais_antigo ? `, o mais antigo de ${fmtDia(sh.mais_antigo)}` : ""}`,
          );
        }
        plataformas[i] = {
          ...plataformas[i],
          integrado: true,
          total: sh.total,
          disponivel: null,
          valorSemData: sh.sem_data !== 0 ? sh.sem_data : null,
          dias: (sh.dias ?? []).map((d) => ({ data: d.data, valor: d.valor })),
          atualizadoEm: sh.atualizado_em ? fmtDataHora(sh.atualizado_em) : null,
          nota: partes.join(" · "),
        };
      }
    } catch {
      // mantém o card como "aguardando integração"
    }

    // Magalu. SEM cronograma: a API não publica data de repasse (a de Análise
    // Financeira é visão contábil, sem data de pagamento — e hoje vem vazia,
    // porque só cobre Entregue/Cancelado faturado). Valor é líquido REAL do
    // pedido (comissão e frete vêm do próprio /seller/v1/orders).
    try {
      const mg = await rpc<MagaluRecebiveisRow>("magalu_recebiveis");
      const i = plataformas.findIndex((p) => p.id === "magalu");
      if (mg && i >= 0) {
        plataformas[i] = {
          ...plataformas[i],
          integrado: true,
          total: mg.total,
          disponivel: null,
          dias: [],
          atualizadoEm: mg.atualizado_em ? fmtDataHora(mg.atualizado_em) : null,
          nota: `${mg.pedidos} ${mg.pedidos === 1 ? "pedido não cancelado" : "pedidos não cancelados"}, líquido real (bruto − comissão − frete)${mg.mais_antigo ? `, desde ${fmtDia(mg.mais_antigo)}` : ""} · a API não registra o que já foi repassado — régua a refinar no 1º repasse`,
        };
      }
    } catch {
      // mantém o card como "aguardando integração"
    }

    // TikTok. FORA DO TOTAL (decisão do Luciano 17/08/2026): sem data de
    // liquidação e com repasse de 73%–101% do pago (a plataforma subsidia), um
    // número único de caixa não se sustenta. O card mostra o bruto REAL pendente
    // de liquidação + a faixa histórica de repasse, como informação.
    try {
      const tt = await rpc<TtRecebiveisRow>("tt_recebiveis");
      const i = plataformas.findIndex((p) => p.id === "tiktok");
      if (tt && i >= 0) {
        const faixa =
          tt.repasse_min != null && tt.repasse_max != null
            ? ` · historicamente o repasse ficou entre ${pctBr(tt.repasse_min)} e ${pctBr(tt.repasse_max)} desse valor (${tt.meses_base} meses medidos)`
            : "";
        plataformas[i] = {
          ...plataformas[i],
          integrado: true,
          foraDoTotal: true,
          rotuloValor: "Pago, a liquidar",
          total: tt.total,
          disponivel: null,
          dias: [],
          atualizadoEm: tt.atualizado_em ? fmtDataHora(tt.atualizado_em) : null,
          nota: `${tt.pedidos} pedidos pagos aguardando liquidação${tt.mais_antigo ? `, o mais antigo de ${fmtDia(tt.mais_antigo)}` : ""}${faixa}`,
        };
      }
    } catch {
      // mantém o card como "aguardando integração"
    }

    return { referencia, plataformas };
  },

  // Linhas ACIMA da Margem de Contribuição, consolidadas de TODOS os canais (reusa getDashboard).
  // Soma as deduções por rótulo, tolerando os labels heterogêneos dos canais (ML separa
  // Comissão/Frete; Shopee combina; TikTok tem "Taxas"). Retorna mapa label→valor.
  async getDreTopo(month: string): Promise<Record<string, number>> {
    const d = await this.getDashboard(month);
    const P = d.plataformasDre;
    const somaDed = (...labels: string[]) =>
      P.reduce((s, p) => s + p.deducoes.filter((x) => labels.includes(x.label)).reduce((a, x) => a + (x.valor ?? 0), 0), 0);
    const difal = somaDed("DIFAL");
    return {
      "Receita Bruta": P.reduce((s, p) => s + (p.faturamentoBruto ?? 0), 0),
      "Vendas Canceladas": P.reduce((s, p) => s + (p.cancelDevolucoes ?? 0), 0),
      "Impostos s/ Vendas": difal, // hoje só DIFAL; IPI não é isolado no Hub
      DIFAL: difal,
      "Comissões/Fretes Marketplaces": somaDed(
        "Comissão", "Frete", "Comissão e Fretes reais cobrados", "Taxas", "Afiliados", "Custo Devoluções",
      ),
      CMV: somaDed("CMV"),
      "Despesas com o Full": somaDed("Full"),
      "Marketing & Tráfego": somaDed("ADS"), // ADS de marketplace; some no C1 junto do marketing próprio (Omie)
    };
  },

  // DRE por SKU de um canal no mês: agrega as linhas (sku×dia) do RPC dre_sku
  // em totais mensais + série diária por SKU. M.C. = fat − CMV − comissão (produto).
  async getDreSku(canal: string, month: string): Promise<SkuDre[]> {
    type Row = { sku: string; titulo: string; data: string; fat: number; cmv: number; comissao: number; frete: number; ads: number };
    const rows = (await rpc<Row[]>("dre_sku", { p_canal: canal, p_month: month })) ?? [];
    const round2 = (n: number) => Math.round(n * 100) / 100;
    const ordDia = (dm: string) => Number(dm.split("/")[0]);
    type Dia = { fat: number; cmv: number; comissao: number; frete: number; ads: number; ord: number };
    const map = new Map<
      string,
      { titulo: string; fat: number; cmv: number; comissao: number; frete: number; ads: number; dias: Map<string, Dia> }
    >();
    for (const r of rows) {
      const cur =
        map.get(r.sku) ?? { titulo: r.titulo ?? r.sku, fat: 0, cmv: 0, comissao: 0, frete: 0, ads: 0, dias: new Map() };
      cur.fat += r.fat; cur.cmv += r.cmv; cur.comissao += r.comissao; cur.frete += r.frete; cur.ads += r.ads;
      if (r.titulo && (!cur.titulo || cur.titulo === r.sku)) cur.titulo = r.titulo;
      const d = cur.dias.get(r.data) ?? { fat: 0, cmv: 0, comissao: 0, frete: 0, ads: 0, ord: ordDia(r.data) };
      d.fat += r.fat; d.cmv += r.cmv; d.comissao += r.comissao; d.frete += r.frete; d.ads += r.ads;
      cur.dias.set(r.data, d);
      map.set(r.sku, cur);
    }
    const out: SkuDre[] = [];
    for (const [sku, v] of map) {
      const mc = round2(v.fat - v.cmv - v.comissao - v.frete - v.ads);
      const serie = Array.from(v.dias.entries())
        .sort((a, b) => a[1].ord - b[1].ord)
        .map(([data, dd]) => ({
          data,
          faturamento: round2(dd.fat),
          cmv: round2(dd.cmv),
          comissao: round2(dd.comissao),
          frete: round2(dd.frete),
          ads: round2(dd.ads),
          outras: 0,
          mc: round2(dd.fat - dd.cmv - dd.comissao - dd.frete - dd.ads),
        }));
      out.push({
        sku,
        titulo: v.titulo ?? sku,
        faturamento: round2(v.fat),
        cmv: round2(v.cmv),
        comissao: round2(v.comissao),
        frete: round2(v.frete),
        ads: round2(v.ads),
        mc,
        mcPct: v.fat > 0 ? Math.round((mc / v.fat) * 10000) / 100 : null,
        serie,
      });
    }
    out.sort((a, b) => b.faturamento - a.faturamento);
    return out;
  },

  async getDashboard(month?: string): Promise<DashboardData> {
    let mes = month;
    if (!mes) {
      const months = await rpc<string[]>("ml_dashboard_months");
      mes = months?.[0]; // mais recente
    }
    if (!mes) {
      // sem nenhum mês na base — devolve tudo vazio (sem números falsos)
      return vazio();
    }

    const a = await rpc<AggReal>("ml_dashboard", { p_month: mes });
    // 3 linhas de topo do mini-DRE do card ML (bruto/cancel/líquido) — REAL.
    const fat = await rpc<FatMl>("ml_faturamento_ml", { p_month: mes });
    // Comissão líquida (régua da margem: paid+partial) — REAL. Dedução com dado.
    const com = await rpc<ComissaoMl>("ml_comissao", { p_month: mes });
    // ADS (product_ads + brand_ads + seguidores) — LÍQUIDO da bonificação BPAD da fatura.
    const ads = await rpc<AdsMl>("ml_ads", { p_month: mes });
    // Custo de devoluções/fricção da fatura ML (líquido dos estornos) — análogo à Shopee.
    const friccao = await rpc<FriccaoMl>("ml_friccao", { p_month: mes });
    // Frete (custo_vendedor de ml_envios) — REAL. Dedução com dado.
    const frete = await rpc<FreteMl>("ml_frete", { p_month: mes });
    // Full (armazenamento/coleta/penalidade de Fulfillment) — REAL. Dedução com dado.
    const full = await rpc<FullMl>("ml_full", { p_month: mes });
    // Afiliados (CVAF do billing) — REAL. Régua creation_date (regime de quando o ML
    // cobra), NÃO data da venda: os R$ do mês são de vendas antigas cobradas com atraso
    // (batch). Bate com a fatura do ML, descasa da competência das vendas — igual Full.
    const afil = await rpc<AfiliadosMl>("sp_afiliados_ml", { p_month: mes });
    // DIFAL (ICMS-DIFAL interestadual, CDIFAL do billing) — REAL. 7ª dedução, ML-only.
    // Régua creation_date (dia da cobrança), mês-calendário, 2 faturas. Imposto tratado
    // como dedução da M.C. (carga tributária completa fica pro módulo Impostos futuro).
    const difal = await rpc<DifalMl>("sp_difal_ml", { p_month: mes });
    // CMV (custo da mercadoria vendida) — REAL. Maior dedução; fecha a M.C.
    const cmv = await rpc<CmvMl>("ml_cmv", { p_month: mes });
    // Séries diárias p/ o gráfico: ML (com custos diretos) + demais canais (só faturamento).
    const diario = await rpc<DreDiaRow[]>("ml_dre_diario", { p_month: mes });
    const canais = await rpc<CanalDiaRow[]>("dre_diario_canais", { p_month: mes });
    // Amazon — bruta (régua Shipped+Unshipped, competência PurchaseDate).
    const azFat = await rpc<FatAz>("az_faturamento", { p_month: mes });
    // Amazon — deduções do settlement (Easy Ship, refund).
    const azDed = await rpc<DedAz>("az_deducoes", { p_month: mes });
    // Amazon — comissão híbrida (real onde confirmado, estimada onde não).
    const azCom = await rpc<ComissaoAz>("az_comissao", { p_month: mes });
    // Amazon — frete híbrido (real MFNPostageFee onde confirmado, R$27,95 estimado onde não).
    const azFrete = await rpc<FreteAz>("az_frete_mes", { p_month: mes });
    // Amazon — CMV (custo × quantidade dos itens vendidos, via ml_custo_produto).
    const azCmv = await rpc<CmvAz>("az_cmv", { p_month: mes });
    // Amazon — ADS (azads_gastos via Advertising API; ingestão azads-diario/colher).
    const azAds = await rpc<AdsAzads>("azads_ads", { p_month: mes });
    // Shopee — bruta (régua COMPLETED, competência create_time BRT).
    const spFat = await rpc<FatSp>("sp_faturamento", { p_month: mes });
    // Shopee — CMV (custo × qty, unaccent no JOIN com ml_custo_produto).
    const spCmv = await rpc<CmvSp>("sp_cmv", { p_month: mes });
    // Shopee — afiliados AMS (order_ams_commission_fee do escrow, separado da comissão).
    const spAfil = await rpc<AfiliSp>("sp_afiliados", { p_month: mes });
    // Shopee — ADS (gasto CPC diário, get_all_cpc_ads_daily_performance). Escopo Ads já
    // no token (a nota "pendente escopo" estava errada). Separado do escrow, sem overlap.
    const spAds = await rpc<AdsSp>("shopee_ads", { p_month: mes });
    // Shopee — DIFAL (ICMS interestadual da carteira, ADJUSTMENT_CENTER_DEDUCT). Cobrança
    // por pedido (ICMS UF destino) + esporádica (fiscalização). Régua creation_date, ML-like.
    const spDifal = await rpc<DifalSp>("shopee_difal", { p_month: mes });
    // Shopee — custo de devoluções finalizadas (estorno via total_adjustment do escrow; as
    // taxas retidas já entram em comissão/frete). Régua não-cancelado, ajuste negativo no escrow.
    const spCustoDev = await rpc<CustoDevSp>("sp_custo_devolucoes", { p_month: mes });
    // Shopee — repasse real (escrow): o dinheiro que caiu na conta, já líquido dos
    // créditos que a decomposição bruta não vê (subsídio de frete, reembolso de voucher).
    // Base da linha "Comissão e Fretes reais cobrados" (= bruta − repasse − afiliados).
    const spRepasse = await rpc<RepasseSp>("sp_repasse", { p_month: mes });
    // SHEIN — bruta (order-detail; competência payment_time BRT; exclui reembolso/danificado/recusado).
    const shFat = await rpc<FatShein>("shein_faturamento", { p_month: mes });
    // SHEIN — deduções reais do pedido (cupons/promos + comissão + taxa de fulfillment).
    const shDed = await rpc<DedShein>("shein_deducoes", { p_month: mes });
    // SHEIN — CMV (shein_itens × ml_custo_produto com vigência; 1 unidade por goodsId).
    const shCmv = await rpc<CmvShein>("shein_cmv", { p_month: mes });
    // Magalu — bruta (amounts.total pago pelo cliente, régua não-cancelado; competência created_at BRT).
    const mgFat = await rpc<FatMg>("magalu_faturamento", { p_month: mes });
    // Magalu — comissão e frete REAIS do pedido (/seller/v1/orders; desconto já embutido na bruta).
    const mgDed = await rpc<DedMg>("magalu_deducoes", { p_month: mes });
    // Magalu — CMV (magalu_itens × ml_custo_produto com vigência, unaccent no sku).
    const mgCmv = await rpc<CmvMg>("magalu_cmv", { p_month: mes });
    // B2B — bruta (NFs por data_emissao, valor_total com IPI).
    const b2bFat = await rpc<FatB2b>("b2b_faturamento", { p_month: mes });
    // B2B — CMV (cruza b2b_itens × ml_custo_produto).
    const b2bCmv = await rpc<CmvB2b>("b2b_cmv", { p_month: mes });
    // TikTok — bruta (Σ revenue_amount by-order, competência create_time BRT, régua não-cancelado+liquidado).
    const ttFat = await rpc<FatTt>("tt_faturamento", { p_month: mes });
    // TikTok — deduções PROJETADAS (real dos liquidados + provisão por take-rate dos demais;
    // afiliado real via Affiliate API quando disponível; ads via tt_ads_diario > settlement).
    const ttDed = await rpc<DedTt>("tt_deducoes_projetado", { p_month: mes });
    // TikTok — CMV (seller_sku × ml_custo_produto, unaccent).
    const ttCmv = await rpc<CmvTt>("tt_cmv", { p_month: mes });

    // Deduções do card ML + M.C. — as 7 com fonte automática (Afiliados=CVAF, DIFAL=CDIFAL do billing).
    // M.C. = Faturamento Líquido − Σ deduções (todas com valor → margem fecha).
    const deducoesMl = DEDUCAO_LABELS_DIFAL.map((label) => {
      if (label === "Comissão") return { label, valor: com.comissao_total_mes };
      if (label === "Frete") return { label, valor: frete.frete_total_mes };
      if (label === "ADS") return { label, valor: ads.ads_total_mes };
      if (label === "Full") return { label, valor: full.full_total_mes };
      if (label === "CMV") return { label, valor: cmv.cmv_total_mes };
      if (label === "Afiliados") return { label, valor: afil.afiliados_total_mes };
      if (label === "DIFAL") return { label, valor: difal.difal_total_mes };
      if (label === "Custo Devoluções") {
        return {
          label,
          valor: friccao.friccao_total,
          nota: friccao.lancamentos > 0 ? `${friccao.lancamentos} lançamentos, líquido` : undefined,
        };
      }
      return { label, valor: null };
    });
    const totalDeducoesMl = deducoesMl.reduce((s, d) => s + (d.valor ?? 0), 0);
    const mcMl = fat.faturamentoLiquido == null
      ? null
      : Math.round((fat.faturamentoLiquido - totalDeducoesMl) * 100) / 100;
    // ── TOPO: NEGÓCIO INTEIRO, faturamento LÍQUIDO e pedidos VÁLIDOS (sem cancelados) ──
    // Cada canal já exclui cancelados pela sua régua; o líquido abate devoluções onde há.
    const azLiquido = azFat.faturamento_bruto
      ? Math.round((azFat.faturamento_bruto - (azDed.refund ?? 0)) * 100) / 100
      : 0;
    const totalVenda =
      (fat.faturamentoLiquido ?? 0) +    // Mercado Livre (líquido)
      (spFat.faturamento_bruto ?? 0) +   // Shopee (líquido = bruto)
      (ttFat.faturamento_liquido ?? 0) + // TikTok (líquido)
      azLiquido +                        // Amazon (bruto − refund)
      Math.round(((shFat.faturamento_bruto ?? 0) - (shFat.cancel_devolucoes ?? 0)) * 100) / 100 + // SHEIN (bruto − devoluções)
      (mgFat.faturamento_bruto ?? 0) +   // Magalu (líquido = bruto, MVP)
      (b2bFat.faturamento_bruto ?? 0);   // B2B (líquido = bruto)
    const totalPedidos =
      (a.totalPedidosValidos ?? 0) +     // ML: paid + partially_refunded
      (spFat.total_pedidos ?? 0) +       // Shopee: COMPLETED
      (ttFat.total_pedidos ?? 0) +       // TikTok: liquidado
      (azFat.total_pedidos ?? 0) +       // Amazon: Shipped+Unshipped
      (shFat.total_pedidos ?? 0) +       // SHEIN: não-cancelados (MVP)
      (mgFat.total_pedidos ?? 0) +       // Magalu: não-cancelados (MVP)
      (b2bFat.total_notas ?? 0);         // B2B: NFs emitidas
    const ticketMedio = totalPedidos > 0 ? totalVenda / totalPedidos : 0;

    // "Provável": MESMA RÉGUA do topo (negócio inteiro, líquido). Os dias vêm do ML
    // (que vende todo dia) como proxy dos dias ativos do mês.
    const mediaVendaDiaria = a.diasComVenda > 0 ? totalVenda / a.diasComVenda : 0;
    const faturamentoCorrenteProvavel = mediaVendaDiaria * (a.diasNoMes || 0);
    // Gráfico mensal e lista "por canal" seguem na base BRUTA do ML.
    const mlVendaBruta = a.totalVenda ?? 0;

    const result: DashboardData = {
      // REAL (da bruta)
      kpis: { totalVenda, totalPedidos, ticketMedio, mcTotal: null },
      meta: { mcMeta: META_MC[mes] ?? META_MC_DEFAULT },
      provavel: {
        mediaVendaDiaria,                 // REAL (trivial: bruta/dias com venda)
        faturamentoCorrenteProvavel,      // REAL (projeção: média × dias do mês)
        mcIdeal: null,                    // sem dado (margem)
        pontoEquilibrio: null,            // sem dado (margem)
        pontoEquilibrioPct: null,         // sem dado (margem)
        retLMedio: null,                  // sem dado (margem)
        mcLMedia: null,                   // sem dado (margem)
        mcLUltMes: null,                  // sem dado (margem)
      },
    margemGauge: { valor: null, max: 214500 },      // sem dado (margem)
      mcMensal: [],                                   // sem dado (margem)
      totalMensal: [
        { mes: labelMesCurto(mes), venda: Math.round((mlVendaBruta / 1_000_000) * 100) / 100, mcVenda: null, mcLiquida: null },
      ],
      plataformas: [
        { nome: "Mercado Livre", valor: mlVendaBruta }, // REAL (bruta ML)
        { nome: "Shopee", valor: spFat.faturamento_bruto || null },
        { nome: "Tik Tok", valor: ttFat.faturamento_bruto || null },
        { nome: "Amazon", valor: azFat.faturamento_bruto || null },
        { nome: "SHEIN", valor: shFat.faturamento_bruto || null },
        { nome: "Magalu", valor: mgFat.faturamento_bruto || null },
        { nome: "B2B", valor: b2bFat.faturamento_bruto || null },
      ],
      // Card ML: topo REAL + as 6 deduções (Comissão/Frete/ADS/Full/CMV reais; Afiliados=0)
      // e a M.C. calculada (Líquido − Σ deduções). Demais plataformas: tudo null (sem
      // integração). UI mostra "sem dados" onde for null.
      plataformasDre: [
        {
          ...dreVazio("Mercado Livre"),
          faturamentoBruto: fat.faturamentoBruto,
          cancelDevolucoes: fat.cancelDevolucoes,
          faturamentoLiquido: fat.faturamentoLiquido,
          deducoes: deducoesMl,
          mc: mcMl,
        },
        (() => {
          const spBruto = spFat.faturamento_bruto || null;
          const spLiquido = spBruto;                       // linha de topo: bruta real (100%)
          const spCmvFull = spCmv.itens_total > 0 ? spCmv.cmv_total : null;
          const cmvNota = spCmv.itens_total > 0
            ? `${spCmv.itens_com_custo} de ${spCmv.itens_total} com custo`
            : undefined;
          // Mesma régua de piso do TikTok. Cobertura Shopee = bruta com escrow / bruta total
          // (escrow chega no READY_TO_SHIP → hoje ~100%; o piso quase nunca dispara aqui).
          const cobertura = spFat.faturamento_bruto > 0
            ? spRepasse.bruta_com_escrow / spFat.faturamento_bruto : 0;
          const cobPct = Math.round(cobertura * 100);

          if (cobertura < PISO_COBERTURA) {
            const deducoesSp = DEDUCAO_LABELS_SHOPEE
              .map((label): { label: string; valor: number | null; nota?: string } =>
                label === "CMV"
                  ? { label, valor: spCmvFull, nota: cmvNota }
                  : { label, valor: null, nota: label === "Comissão e Fretes reais cobrados" ? "aguardando liquidação" : undefined },
              );
            const margem = spBruto != null && spCmvFull != null
              ? Math.round((spBruto - spCmvFull) * 100) / 100
              : null;
            return {
              ...dreVazio("Shopee"),
              faturamentoBruto: spBruto,
              cancelDevolucoes: 0,
              faturamentoLiquido: spLiquido,
              deducoes: deducoesSp,
              margemBruta: margem,
              mc: null,
              mcNota: `cobertura ${cobPct}% — em consolidação`,
            };
          }

          // Acima do piso: M.C. sobre o subconjunto COM ESCROW dos dois lados (bruta, repasse
          // e CMV do mesmo conjunto). "Comissão e Fretes reais cobrados" = o que a Shopee
          // EFETIVAMENTE reteve (escrow, já com subsídio de frete/voucher creditado), derivado
          // do repasse real: (bruta − escrow) − afiliados. A 100% coincide com o total.
          const spCmvEsc = spCmv.itens_total > 0 ? spCmv.cmv_com_escrow : null;
          const brutaEsc = spRepasse.bruta_com_escrow;
          const comFreteReal = spRepasse.repasse_com_escrow != null
            ? Math.round(((brutaEsc - spRepasse.repasse_com_escrow) - (spAfil.afiliados_total || 0)) * 100) / 100
            : null;
          const deducoesSp = DEDUCAO_LABELS_SHOPEE
            .map((label): { label: string; valor: number | null; nota?: string } => {
              if (label === "Comissão e Fretes reais cobrados") return { label, valor: comFreteReal };
              if (label === "ADS") return { label, valor: spAds.ads_total_mes || null };
              if (label === "Full") return { label, valor: 0 };
              if (label === "Afiliados") return { label, valor: spAfil.afiliados_total || null };
              if (label === "DIFAL") return { label, valor: spDifal.difal_total_mes || null };
              if (label === "CMV") return { label, valor: spCmvEsc, nota: cmvNota };
              if (label === "Custo Devoluções") return { label, valor: spCustoDev.custo_total || null };
              return { label, valor: null };
            });
          const totalDeducoesSp = deducoesSp.reduce((s, d) => s + (d.valor ?? 0), 0);
          const spMc = Math.round((brutaEsc - totalDeducoesSp) * 100) / 100;
          return {
            ...dreVazio("Shopee"),
            faturamentoBruto: spBruto,
            cancelDevolucoes: 0,
            faturamentoLiquido: spLiquido,
            deducoes: deducoesSp,
            mc: spMc,
            mcNota: cobertura < 1 ? `cobertura ${cobPct}% — M.C. sobre pedidos com escrow` : undefined,
          };
        })(),
        (() => {
          const ttBruto = ttFat.faturamento_bruto || null;
          // M.C. PROJETADA (decisão 12/08/2026): receita cheia contra deduções cheias —
          // reais nos pedidos liquidados, provisionadas por take-rate móvel nos demais
          // (afiliado real via Affiliate API quando houver; ads via tt_ads_diario quando
          // houver). A provisão é substituída pelo real pedido a pedido conforme o
          // settlement chega; pct_liquidado diz quanto do número já é batido.
          const ttLiquido = ttFat.faturamento_liquido || null;
          const cmvNota = ttCmv.itens_total > 0
            ? `${ttCmv.itens_com_custo} de ${ttCmv.itens_total} com custo`
            : undefined;
          const cobPct = ttDed.pct_liquidado ?? 0;
          const ttCmvFull = ttCmv.itens_total > 0 ? ttCmv.cmv_total : null;
          const provNota = ttDed.pedidos_provisionados > 0
            ? `${ttDed.pedidos_liquidados} de ${ttDed.pedidos} liquidados — resto provisionado`
            : undefined;
          const adsNota = ttDed.ads_fonte === "tt_ads_diario"
            ? "gasto real diário (GMV Max)"
            : (ttDed.pedidos_provisionados > 0 && ttDed.ads > 0 ? "settlement + provisão" : undefined);
          const afilNota = ttDed.pedidos_afiliado_real > 0
            ? `${ttDed.pedidos_afiliado_real} pedidos com comissão real`
            : undefined;
          const deducoesTt = DEDUCAO_LABELS_TT.map((label) => {
            if (label === "Comissão") return { label, valor: ttDed.comissao || null, nota: provNota };
            if (label === "Taxas") return { label, valor: ttDed.taxas || null };
            if (label === "Frete") return { label, valor: ttDed.frete || null };
            if (label === "ADS") return { label, valor: ttDed.ads ?? 0, nota: adsNota };
            if (label === "Afiliados") return { label, valor: ttDed.afiliados ?? 0, nota: afilNota };
            if (label === "CMV") return { label, valor: ttCmvFull, nota: cmvNota };
            return { label, valor: null };
          });
          const totalDeducoesTt = deducoesTt.reduce((s, d) => s + (d.valor ?? 0), 0);
          const ttMc = ttLiquido != null
            ? Math.round((ttLiquido - totalDeducoesTt) * 100) / 100
            : null;
          return {
            ...dreVazio("TikTok Shop"),
            faturamentoBruto: ttBruto,
            cancelDevolucoes: ttBruto != null ? ttFat.devolucoes : null,
            faturamentoLiquido: ttLiquido,
            deducoes: deducoesTt,
            mc: ttMc,
            mcNota: cobPct < 100
              ? `M.C. projetada — ${cobPct}% liquidado, restante provisionado`
              : undefined,
          };
        })(),
        (() => {
          const azBruto = azFat.faturamento_bruto || null;
          const azRefund = azBruto != null ? azDed.refund : null;
          const azLiquido = azBruto != null
            ? Math.round((azFat.faturamento_bruto - azDed.refund) * 100) / 100
            : null;
          const comNota = azCom.pedidos_total > 0
            ? `${azCom.pedidos_confirmados} de ${azCom.pedidos_total} confirmados`
            : undefined;
          const freteNota = azFrete.pedidos_total > 0
            ? `${azFrete.pedidos_confirmados} de ${azFrete.pedidos_total} confirmados`
            : undefined;
          const azCmvVal = azCmv.itens_total > 0 ? azCmv.cmv_total : null;
          const cmvNota = azCmv.itens_total > 0
            ? `${azCmv.itens_com_custo} de ${azCmv.itens_total} com custo`
            : undefined;
          const deducoesAz = DEDUCAO_LABELS
            .filter((l) => l !== "Afiliados")
            .map((label) => {
              if (label === "Comissão") return { label, valor: azCom.comissao_total || null, nota: comNota };
              if (label === "Frete") return { label, valor: azFrete.frete_total || null, nota: freteNota };
              if (label === "CMV") return { label, valor: azCmvVal, nota: cmvNota };
              // ADS real via Advertising API (azads_gastos). 0 é zero de verdade:
              // mês sem linha = Amazon não registrou gasto (validado vs painel 03/08/2026).
              if (label === "ADS") {
                return {
                  label,
                  valor: Math.round(azAds.ads_total_mes * 100) / 100,
                  nota: azAds.dias_com_dado > 0 ? `${azAds.dias_com_dado} dias com gasto` : undefined,
                };
              }
              if (label === "Full") return { label, valor: 0 };
              return { label, valor: null };
            });
          const totalDeducoesAz = deducoesAz.reduce((s, d) => s + (d.valor ?? 0), 0);
          const azMc = azLiquido != null
            ? Math.round((azLiquido - totalDeducoesAz) * 100) / 100
            : null;
          return {
            ...dreVazio("Amazon"),
            faturamentoBruto: azBruto,
            cancelDevolucoes: azRefund,
            faturamentoLiquido: azLiquido,
            deducoes: deducoesAz,
            mc: azMc,
          };
        })(),
        (() => {
          // SHEIN: bruta = preço PAGO pelo cliente (bate com a central de vendedores);
          // "Subsídio SHEIN" entra NEGATIVO (crédito — a SHEIN repassa sobre base maior
          // que o preço pago). pago − comissão − taxa + subsídio = estimatedGrossIncome
          // da API, centavo a centavo. Conciliação com o settlement é fase futura.
          const shBruto = shFat.faturamento_bruto || null;
          const shLiquido = shBruto != null
            ? Math.round((shFat.faturamento_bruto - (shFat.cancel_devolucoes ?? 0)) * 100) / 100
            : null;
          const shCmvVal = shCmv.itens_total > 0 ? shCmv.cmv_total : null;
          const cmvNota = shCmv.itens_total > 0
            ? `${shCmv.itens_com_custo} de ${shCmv.itens_total} com custo`
            : undefined;
          const deducoesSh = DEDUCAO_LABELS_SHEIN.map((label): { label: string; valor: number | null; nota?: string } => {
            if (label === "Comissão") return { label, valor: shDed.comissao || null };
            if (label === "Taxa de serviço") return { label, valor: shDed.taxa_servico || null };
            if (label === "Subsídio SHEIN")
              return { label, valor: shDed.subsidio ? -shDed.subsidio : null, nota: "desconto bancado pela SHEIN — crédito" };
            if (label === "CMV") return { label, valor: shCmvVal, nota: cmvNota };
            return { label, valor: null };
          });
          const totalDeducoesSh = deducoesSh.reduce((s, d) => s + (d.valor ?? 0), 0);
          const shMc = shLiquido != null
            ? Math.round((shLiquido - totalDeducoesSh) * 100) / 100
            : null;
          return {
            ...dreVazio("SHEIN"),
            faturamentoBruto: shBruto,
            cancelDevolucoes: shBruto != null ? (shFat.cancel_devolucoes ?? 0) : null,
            faturamentoLiquido: shLiquido,
            deducoes: deducoesSh,
            mc: shMc,
            mcNota: shBruto != null ? "valores do pedido — settlement na próxima fase" : null,
          };
        })(),
        (() => {
          // Magalu (MVP): bruta = amounts.total PAGO pelo cliente (pós-desconto — o desconto
          // NÃO é dedução, seria dupla contagem). Comissão/frete REAIS do pedido
          // (/seller/v1/orders). Repasse (Análise Financeira) é fase futura.
          const mgBruto = mgFat.faturamento_bruto || null;
          const mgLiquido = mgBruto;
          const mgCmvVal = mgCmv.itens_total > 0 ? mgCmv.cmv_total : null;
          const cmvNotaMg = mgCmv.itens_total > 0
            ? `${mgCmv.itens_com_custo} de ${mgCmv.itens_total} com custo`
            : undefined;
          const deducoesMg = DEDUCAO_LABELS_MAGALU.map((label): { label: string; valor: number | null; nota?: string } => {
            if (label === "Comissão") return { label, valor: mgDed.comissao || null };
            if (label === "Frete") return { label, valor: mgDed.frete || null };
            if (label === "CMV") return { label, valor: mgCmvVal, nota: cmvNotaMg };
            return { label, valor: null };
          });
          const totalDeducoesMg = deducoesMg.reduce((s, d) => s + (d.valor ?? 0), 0);
          const mgMc = mgLiquido != null
            ? Math.round((mgLiquido - totalDeducoesMg) * 100) / 100
            : null;
          return {
            ...dreVazio("Magalu"),
            faturamentoBruto: mgBruto,
            cancelDevolucoes: mgBruto != null ? 0 : null,
            faturamentoLiquido: mgLiquido,
            deducoes: deducoesMg,
            mc: mgMc,
            mcNota: mgBruto != null ? "valores do pedido — repasse na fase 100%" : null,
          };
        })(),
        (() => {
          const viBruto = b2bFat.faturamento_bruto || null;
          const viLiquido = viBruto;
          const viCmvVal = b2bCmv.itens_total > 0 ? b2bCmv.cmv_total : null;
          const cmvNota = b2bCmv.itens_total > 0
            ? `${b2bCmv.itens_com_custo} de ${b2bCmv.itens_total} com custo`
            : undefined;
          const deducoesVi = [{ label: "CMV", valor: viCmvVal, nota: cmvNota }];
          const viMc = viLiquido != null
            ? Math.round((viLiquido - (viCmvVal ?? 0)) * 100) / 100
            : null;
          return {
            ...dreVazio("B2B"),
            faturamentoBruto: viBruto,
            cancelDevolucoes: 0,
            faturamentoLiquido: viLiquido,
            deducoes: deducoesVi,
            mc: viMc,
          };
        })(),
      ],
      serieDiaria: [],                                // preenchido abaixo (todos os canais)
      porCanal: [],                                   // preenchido abaixo (dashboard por canal)
      vendasDiarias: a.vendasDiarias ?? [],           // REAL (série diária da bruta)
    };

    // ── Séries diárias: Faturamento + M.C. por dia, POR CANAL e no TOTAL ──
    // Cada canal: M.C. diária = contribuição direta do dia (fat − custos diretos REAIS)
    // menos o RATEIO proporcional do resíduo mensal (custos por ciclo: Full/afiliados/DIFAL
    // no ML; DIFAL/devoluções na Shopee), de modo que Σ(M.C. diária) = M.C. do mês do canal.
    // TikTok/Amazon/B2B fecham exatos (resíduo ~0); ML e Shopee têm rateio pequeno.
    const ordDia = (dm: string) => Number(dm.split("/")[0]);
    const r2 = (n: number) => Math.round(n * 100) / 100;
    type DiaComp = { data: string; fat: number; cmv: number; comissao: number; frete: number; ads: number; subsidio: number };
    // M.C. diária = fat − (cmv+comissão+frete+ads REAIS do dia) + subsídio (crédito da
    // plataforma) − "outras" (rateio do resíduo mensal: afiliados/DIFAL/Full/devoluções),
    // de modo que Σ(M.C.) = M.C. do mês do canal.
    // Cada item carrega a COMPOSIÇÃO (cmv/comissão/frete/ads/subsídio/outras) → gráfico de
    // despesas. O subsídio sai NEGATIVO no item para Σ(segmentos) = faturamento.
    const reconcilia = (rows: DiaComp[], mcMes: number | null): SerieDiariaItem[] => {
      const fatMes = rows.reduce((s, r) => s + r.fat, 0);
      const diretaSoma = rows.reduce(
        (s, r) => s + (r.fat - r.cmv - r.comissao - r.frete - r.ads + r.subsidio),
        0,
      );
      const residual = mcMes != null ? diretaSoma - mcMes : 0;
      return rows
        .slice()
        .sort((a, b) => ordDia(a.data) - ordDia(b.data))
        .map((r) => {
          const outras = fatMes > 0 ? residual * (r.fat / fatMes) : 0;
          const mc = r.fat - r.cmv - r.comissao - r.frete - r.ads + r.subsidio - outras;
          return {
            data: r.data,
            faturamento: r2(r.fat),
            cmv: r2(r.cmv),
            comissao: r2(r.comissao),
            frete: r2(r.frete),
            ads: r2(r.ads),
            subsidio: r2(-r.subsidio),
            outras: r2(outras),
            mc: r2(mc),
          };
        });
    };

    // Linhas (fat + componentes de custo) por canal.
    const rowsPorCanal: Record<string, DiaComp[]> = {
      ml: (diario ?? []).map((d) => ({
        data: d.data, fat: d.fat, cmv: d.cmv, comissao: d.comissao, frete: d.frete, ads: d.ads, subsidio: 0,
      })),
    };
    for (const r of canais ?? []) {
      (rowsPorCanal[r.canal] ??= []).push({
        data: r.data, fat: r.fat, cmv: r.cmv, comissao: r.comissao, frete: r.frete, ads: r.ads,
        subsidio: r.subsidio ?? 0,
      });
    }
    const mcDe = (nome: string) => result.plataformasDre.find((p) => p.nome === nome)?.mc ?? null;
    const mcPorKey: Record<string, number | null> = {
      ml: mcMl,
      sp: mcDe("Shopee"),
      tt: mcDe("TikTok Shop"),
      az: mcDe("Amazon"),
      sh: mcDe("SHEIN"),
      mg: mcDe("Magalu"),
      b2b: mcDe("B2B"),
    };
    const seriePorKey: Record<string, SerieDiariaItem[]> = {};
    for (const key of Object.keys(rowsPorCanal)) {
      seriePorKey[key] = reconcilia(rowsPorCanal[key], mcPorKey[key] ?? null);
    }

    // Série TOTAL = merge das séries por canal, por dia (soma fat, M.C. e composição).
    const diaTot = new Map<string, {
      fat: number; mc: number; cmv: number; comissao: number; frete: number; ads: number; subsidio: number; outras: number;
    }>();
    for (const key of Object.keys(seriePorKey)) {
      for (const s of seriePorKey[key]) {
        const cur = diaTot.get(s.data) ?? { fat: 0, mc: 0, cmv: 0, comissao: 0, frete: 0, ads: 0, subsidio: 0, outras: 0 };
        cur.fat += s.faturamento;
        cur.mc += s.mc;
        cur.cmv += s.cmv ?? 0;
        cur.comissao += s.comissao ?? 0;
        cur.frete += s.frete ?? 0;
        cur.ads += s.ads ?? 0;
        cur.subsidio += s.subsidio ?? 0;
        cur.outras += s.outras ?? 0;
        diaTot.set(s.data, cur);
      }
    }
    result.serieDiaria = Array.from(diaTot.entries())
      .sort((x, y) => ordDia(x[0]) - ordDia(y[0]))
      .map(([data, v]) => ({
        data,
        faturamento: r2(v.fat),
        mc: r2(v.mc),
        cmv: r2(v.cmv),
        comissao: r2(v.comissao),
        frete: r2(v.frete),
        ads: r2(v.ads),
        subsidio: r2(v.subsidio),
        outras: r2(v.outras),
      }));

    // ── Dashboard isolado por canal (para o "Ver mais") ──
    const pedidosPorKey: Record<string, number> = {
      ml: a.totalPedidosValidos ?? 0,
      sp: spFat.total_pedidos ?? 0,
      tt: ttFat.total_pedidos ?? 0,
      az: azFat.total_pedidos ?? 0,
      sh: shFat.total_pedidos ?? 0,
      mg: mgFat.total_pedidos ?? 0,
      b2b: b2bFat.total_notas ?? 0,
    };
    result.porCanal = CANAIS.map((cm) => {
      const dre = result.plataformasDre.find((p) => p.nome === cm.nome);
      const serie = seriePorKey[cm.key] ?? [];
      const liquido = dre?.faturamentoLiquido ?? 0;
      const pedidos = pedidosPorKey[cm.key] ?? 0;
      const diasComVenda = serie.length;
      const mediaVendaDiaria = diasComVenda > 0 ? liquido / diasComVenda : 0;
      return {
        id: cm.id,
        nome: cm.nome,
        kpis: {
          totalVenda: liquido,
          totalPedidos: pedidos,
          ticketMedio: pedidos > 0 ? liquido / pedidos : 0,
          mcTotal: dre?.mc ?? null,
        },
        meta: { mcMeta: META_MC_CANAL[cm.id] ?? null },
        provavel: {
          mediaVendaDiaria,
          faturamentoCorrenteProvavel: mediaVendaDiaria * (a.diasNoMes || 0),
          mcIdeal: null,
          pontoEquilibrio: null,
          pontoEquilibrioPct: null,
          retLMedio: null,
          mcLMedia: null,
          mcLUltMes: null,
        },
        serieDiaria: serie,
        dre: dre ?? dreVazio(cm.nome),
      };
    });
    // MC Total = soma das M.C. de todos os canais (ignora quem não tem M.C. calculada).
    const mcs = result.plataformasDre
      .map((p) => p.mc)
      .filter((v): v is number => v != null);
    result.kpis.mcTotal = mcs.length
      ? Math.round(mcs.reduce((s, v) => s + v, 0) * 100) / 100
      : null;
    return result;
  },
};

/** Dashboard totalmente vazio (quando não há mês na base) — sem números falsos. */
function vazio(): DashboardData {
  return {
    kpis: { totalVenda: 0, totalPedidos: 0, ticketMedio: 0, mcTotal: null },
    meta: { mcMeta: null },
    provavel: {
      mediaVendaDiaria: 0, faturamentoCorrenteProvavel: 0,
      mcIdeal: null, pontoEquilibrio: null, pontoEquilibrioPct: null,
      retLMedio: null, mcLMedia: null, mcLUltMes: null,
    },
    serieDiaria: [],
    porCanal: [],
    margemGauge: { valor: null, max: 214500 },
    mcMensal: [],
    totalMensal: [],
    plataformas: [
      { nome: "Mercado Livre", valor: null },
      { nome: "Shopee", valor: null },
      { nome: "Tik Tok", valor: null },
      { nome: "Amazon", valor: null },
      { nome: "SHEIN", valor: null },
      { nome: "Magalu", valor: null },
      { nome: "B2B", valor: null },
    ],
    plataformasDre: [
      dreVazio("Mercado Livre"),
      dreVazio("Shopee"),
      dreVazio("TikTok Shop"),
      dreVazio("Amazon"),
      dreVazio("SHEIN"),
      dreVazio("Magalu"),
      dreVazio("B2B"),
    ],
    vendasDiarias: [],
  };
}
