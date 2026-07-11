import "server-only";

import type { DashboardData, DataProvider, Month, PlataformaDre, VendaDiaria } from "./types";

/** Labels das 6 deduções do mini-DRE, na ordem do card. */
const DEDUCAO_LABELS = ["Comissão", "Frete", "ADS", "Full", "Afiliados", "CMV"];
/** ML e Shopee cobram DIFAL (ICMS interestadual) — 7ª linha, antes do CMV. */
const DEDUCAO_LABELS_DIFAL = ["Comissão", "Frete", "ADS", "Full", "Afiliados", "DIFAL", "CMV"];
/** TikTok: "Taxas" é linha própria (sfp_service_fee + fee_per_item); sem "Full". */
const DEDUCAO_LABELS_TT = ["Comissão", "Taxas", "Frete", "ADS", "Afiliados", "CMV"];

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

interface AggReal {
  totalVenda: number;
  totalPedidos: number;
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

/** Retorno do RPC ml_ads (gasto de ADS do mês: product_ads + brand_ads). */
interface AdsMl {
  ads_total_mes: number;
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

/** Retorno do RPC sp_faturamento (bruta Shopee do mês, régua COMPLETED). */
interface FatSp {
  faturamento_bruto: number;
  total_pedidos: number;
}

/** Retorno do RPC sp_comissao (comissão + taxa de serviço Shopee). */
interface ComissaoSp {
  comissao_total: number;
  pedidos_com_escrow: number;
  pedidos_total: number;
}

/** Retorno do RPC sp_frete (frete Shopee do mês). */
interface FreteSp {
  frete_total: number;
  pedidos_com_frete: number;
  pedidos_total: number;
}

/** Retorno do RPC sp_cmv (CMV Shopee via ml_custo_produto + unaccent). */
interface CmvSp {
  cmv_total: number;
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
  total_pedidos: number;
  settlement: number;
}

/** Retorno do RPC tt_deducoes (finance by-order: comissão/taxas/frete/ads/afiliados; taxas é residual). */
interface DedTt {
  comissao: number;
  taxas: number;
  frete: number;
  ads: number;
  afiliados: number;
  pedidos: number;
}

/** Retorno do RPC tt_cmv (CMV TikTok via ml_custo_produto + unaccent no seller_sku). */
interface CmvTt {
  cmv_total: number;
  itens_com_custo: number;
  itens_total: number;
}

export const supabaseProvider: DataProvider = {
  async listAvailableMonths(): Promise<Month[]> {
    // Só os meses que EXISTEM nas tabelas (hoje: junho/2026).
    const months = await rpc<string[]>("ml_dashboard_months");
    return (months ?? []).map((value) => ({ value, label: labelMes(value) }));
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
    // ADS (product_ads + brand_ads) — REAL. Dedução com dado.
    const ads = await rpc<AdsMl>("ml_ads", { p_month: mes });
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
    // Shopee — bruta (régua COMPLETED, competência create_time BRT).
    const spFat = await rpc<FatSp>("sp_faturamento", { p_month: mes });
    // Shopee — comissão + taxa de serviço (do escrow).
    const spCom = await rpc<ComissaoSp>("sp_comissao", { p_month: mes });
    // Shopee — frete (actual_shipping_fee do escrow).
    const spFrete = await rpc<FreteSp>("sp_frete", { p_month: mes });
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
    // B2B — bruta (NFs por data_emissao, valor_total com IPI).
    const b2bFat = await rpc<FatB2b>("b2b_faturamento", { p_month: mes });
    // B2B — CMV (cruza b2b_itens × ml_custo_produto).
    const b2bCmv = await rpc<CmvB2b>("b2b_cmv", { p_month: mes });
    // TikTok — bruta (Σ revenue_amount by-order, competência create_time BRT, régua não-cancelado+liquidado).
    const ttFat = await rpc<FatTt>("tt_faturamento", { p_month: mes });
    // TikTok — deduções finance by-order (comissão/taxas/frete/ads/afiliados; taxas residual, reconcilia no fee_and_tax).
    const ttDed = await rpc<DedTt>("tt_deducoes", { p_month: mes });
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
      return { label, valor: null };
    });
    const totalDeducoesMl = deducoesMl.reduce((s, d) => s + (d.valor ?? 0), 0);
    const mcMl = fat.faturamentoLiquido == null
      ? null
      : Math.round((fat.faturamentoLiquido - totalDeducoesMl) * 100) / 100;
    const totalVenda = a.totalVenda ?? 0;
    const totalPedidos = a.totalPedidos ?? 0;
    const ticketMedio = totalPedidos > 0 ? totalVenda / totalPedidos : 0;
    const mediaVendaDiaria = a.diasComVenda > 0 ? totalVenda / a.diasComVenda : 0;
    const faturamentoCorrenteProvavel = mediaVendaDiaria * (a.diasNoMes || 0);

    return {
      // REAL (da bruta)
      kpis: { totalVenda, totalPedidos, ticketMedio },
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
        { mes: labelMesCurto(mes), venda: Math.round((totalVenda / 1_000_000) * 100) / 100, mcVenda: null, mcLiquida: null },
      ],
      plataformas: [
        { nome: "Mercado Livre", valor: totalVenda }, // REAL (toda a base é ML)
        { nome: "Shopee", valor: spFat.faturamento_bruto || null },
        { nome: "Tik Tok", valor: ttFat.faturamento_bruto || null },
        { nome: "Amazon", valor: azFat.faturamento_bruto || null },
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
          const spLiquido = spBruto;
          const comNota = spCom.pedidos_total > 0
            ? `${spCom.pedidos_com_escrow} de ${spCom.pedidos_total} com escrow`
            : undefined;
          const freteNota = spFrete.pedidos_total > 0
            ? `${spFrete.pedidos_com_frete} de ${spFrete.pedidos_total} com frete`
            : undefined;
          const spCmvVal = spCmv.itens_total > 0 ? spCmv.cmv_total : null;
          const cmvNota = spCmv.itens_total > 0
            ? `${spCmv.itens_com_custo} de ${spCmv.itens_total} com custo`
            : undefined;
          const afilNota = spAfil.pedidos_total > 0
            ? `${spAfil.pedidos_com_ams} de ${spAfil.pedidos_total} com afiliado`
            : undefined;
          const deducoesSp = DEDUCAO_LABELS_DIFAL
            .map((label) => {
              if (label === "Comissão") return { label, valor: spCom.comissao_total || null, nota: comNota };
              if (label === "Frete") return { label, valor: spFrete.frete_total || null, nota: freteNota };
              if (label === "Afiliados") return { label, valor: spAfil.afiliados_total || null, nota: afilNota };
              if (label === "CMV") return { label, valor: spCmvVal, nota: cmvNota };
              if (label === "ADS") return { label, valor: spAds.ads_total_mes || null };
              if (label === "DIFAL") return { label, valor: spDifal.difal_total_mes || null };
              if (label === "Full") return { label, valor: 0 };
              return { label, valor: null };
            });
          const totalDeducoesSp = deducoesSp.reduce((s, d) => s + (d.valor ?? 0), 0);
          const spMc = spLiquido != null
            ? Math.round((spLiquido - totalDeducoesSp) * 100) / 100
            : null;
          return {
            ...dreVazio("Shopee"),
            faturamentoBruto: spBruto,
            cancelDevolucoes: 0,
            faturamentoLiquido: spLiquido,
            deducoes: deducoesSp,
            mc: spMc,
          };
        })(),
        (() => {
          const ttBruto = ttFat.faturamento_bruto || null;
          // Bruta = gross antes da devolução; líquido = revenue_amount (base da M.C., NÃO muda com a
          // devolução explícita). Cancel/Devoluções = refund líquido (7 pedidos em jun/2026).
          const ttLiquido = ttFat.faturamento_liquido || null;
          const ttCmvVal = ttCmv.itens_total > 0 ? ttCmv.cmv_total : null;
          const cmvNota = ttCmv.itens_total > 0
            ? `${ttCmv.itens_com_custo} de ${ttCmv.itens_total} com custo`
            : undefined;
          const covNota = ttFat.total_pedidos > 0
            ? `${ttDed.pedidos} de ${ttFat.total_pedidos} liquidados`
            : undefined;
          const deducoesTt = DEDUCAO_LABELS_TT.map((label) => {
            if (label === "Comissão") return { label, valor: ttDed.comissao || null, nota: covNota };
            if (label === "Taxas") return { label, valor: ttDed.taxas || null };
            if (label === "Frete") return { label, valor: ttDed.frete || null };
            if (label === "ADS") return { label, valor: ttDed.ads ?? 0 };
            if (label === "Afiliados") return { label, valor: ttDed.afiliados ?? 0 };
            if (label === "CMV") return { label, valor: ttCmvVal, nota: cmvNota };
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
              if (label === "ADS" || label === "Full") return { label, valor: 0 };
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
      vendasDiarias: a.vendasDiarias ?? [],           // REAL (série diária da bruta)
    };
  },
};

/** Dashboard totalmente vazio (quando não há mês na base) — sem números falsos. */
function vazio(): DashboardData {
  return {
    kpis: { totalVenda: 0, totalPedidos: 0, ticketMedio: 0 },
    provavel: {
      mediaVendaDiaria: 0, faturamentoCorrenteProvavel: 0,
      mcIdeal: null, pontoEquilibrio: null, pontoEquilibrioPct: null,
      retLMedio: null, mcLMedia: null, mcLUltMes: null,
    },
    margemGauge: { valor: null, max: 214500 },
    mcMensal: [],
    totalMensal: [],
    plataformas: [
      { nome: "Mercado Livre", valor: null },
      { nome: "Shopee", valor: null },
      { nome: "Tik Tok", valor: null },
      { nome: "Amazon", valor: null },
      { nome: "B2B", valor: null },
    ],
    plataformasDre: [
      dreVazio("Mercado Livre"),
      dreVazio("Shopee"),
      dreVazio("TikTok Shop"),
      dreVazio("Amazon"),
      dreVazio("B2B"),
    ],
    vendasDiarias: [],
  };
}
