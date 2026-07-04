import "server-only";

import type { DashboardData, DataProvider, Month, PlataformaDre, VendaDiaria } from "./types";

/** Labels das 6 deduções do mini-DRE, na ordem do card. */
const DEDUCAO_LABELS = ["Comissão", "Frete", "ADS", "Full", "Afiliados", "CMV"];

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

    // Deduções do card ML + M.C. Afiliados = 0 por ora (sem fonte automática, imaterial).
    // M.C. = Faturamento Líquido − Σ deduções (todas as 6 com valor → margem fecha).
    const deducoesMl = DEDUCAO_LABELS.map((label) => {
      if (label === "Comissão") return { label, valor: com.comissao_total_mes };
      if (label === "Frete") return { label, valor: frete.frete_total_mes };
      if (label === "ADS") return { label, valor: ads.ads_total_mes };
      if (label === "Full") return { label, valor: full.full_total_mes };
      if (label === "CMV") return { label, valor: cmv.cmv_total_mes };
      if (label === "Afiliados") return { label, valor: 0 };
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
        { nome: "Shopee", valor: null },              // sem integração
        { nome: "Tik Tok", valor: null },             // sem integração
        { nome: "Amazon", valor: azFat.faturamento_bruto || null },
        { nome: "Vendas Internas", valor: null },     // sem integração
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
        dreVazio("Shopee"),
        dreVazio("TikTok Shop"),
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
          const azMc = azLiquido != null
            ? Math.round((azLiquido - (azCom.comissao_total || 0) - (azFrete.frete_total || 0)) * 100) / 100
            : null;
          return {
            ...dreVazio("Amazon"),
            faturamentoBruto: azBruto,
            cancelDevolucoes: azRefund,
            faturamentoLiquido: azLiquido,
            deducoes: DEDUCAO_LABELS.map((label) => {
              if (label === "Comissão") return { label, valor: azCom.comissao_total || null, nota: comNota };
              if (label === "Frete") return { label, valor: azFrete.frete_total || null, nota: freteNota };
              return { label, valor: null };
            }),
            mc: azMc,
          };
        })(),
        dreVazio("Vendas Internas"),
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
      { nome: "Vendas Internas", valor: null },
    ],
    plataformasDre: [
      dreVazio("Mercado Livre"),
      dreVazio("Shopee"),
      dreVazio("TikTok Shop"),
      dreVazio("Amazon"),
      dreVazio("Vendas Internas"),
    ],
    vendasDiarias: [],
  };
}
