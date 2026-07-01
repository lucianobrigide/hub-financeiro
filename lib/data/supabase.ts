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
        { nome: "Amazon", valor: null },              // sem integração
        { nome: "Vendas Internas", valor: null },     // sem integração
      ],
      // Card ML: topo REAL (bruto/cancel/líquido) + Comissão e ADS REAIS nas deduções; as
      // outras 4 deduções (Frete/Full/Afiliados/CMV) e a M.C. seguem null (sem dado ainda).
      // Demais plataformas: tudo null (sem integração). UI mostra "sem dados" onde for null.
      plataformasDre: [
        {
          ...dreVazio("Mercado Livre"),
          faturamentoBruto: fat.faturamentoBruto,
          cancelDevolucoes: fat.cancelDevolucoes,
          faturamentoLiquido: fat.faturamentoLiquido,
          deducoes: DEDUCAO_LABELS.map((label) => {
            if (label === "Comissão") return { label, valor: com.comissao_total_mes };
            if (label === "ADS") return { label, valor: ads.ads_total_mes };
            return { label, valor: null };
          }),
        },
        dreVazio("Shopee"),
        dreVazio("TikTok Shop"),
        dreVazio("Amazon"),
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
