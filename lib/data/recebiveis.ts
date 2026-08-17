import type { RecebiveisPlataforma } from "./types";

/**
 * Fila de integração dos recebíveis (aba F.C. Projetado).
 *
 * Cada entrada é uma FONTE DE DINHEIRO, não um canal de venda: o que importa aqui
 * é de qual conta/repasse o valor cai. Por isso o Mercado Livre aparece como
 * "Mercado Pago" — é lá que o dinheiro fica retido até liberar.
 *
 * A ordem é a ordem de construção combinada: Mercado Pago primeiro, depois
 * plataforma por plataforma. Ao integrar uma, trocar `integrado` para true e
 * preencher `total`/`dias` no provider — a UI não muda.
 *
 * REGRA DURA: enquanto não integrado, total = null e dias = []. Nunca R$ 0 falso.
 */
export const RECEBIVEIS_ROSTER: readonly Omit<
  RecebiveisPlataforma,
  "total" | "dias" | "disponivel" | "atualizadoEm"
>[] = [
  {
    // INTEGRADO 17/08/2026 (RPC mp_recebiveis). Usa a MESMA credencial do Mercado
    // Livre — api.mercadopago.com aceita o access_token de ml_oauth_state.
    id: "mercado-pago",
    nome: "Mercado Pago",
    fonte: "API do Mercado Pago — pagamentos a liberar (vendas do Mercado Livre), líquido real por data de liberação",
    integrado: false,
    nota: null,
  },
  {
    id: "shopee",
    nome: "Shopee",
    fonte: "escrow do pedido (repasse) — já ingerido em shopee_escrow",
    integrado: false,
    nota: null,
  },
  {
    id: "tiktok",
    nome: "TikTok Shop",
    fonte: "settlement por pedido (pós-entrega)",
    integrado: false,
    nota: null,
  },
  {
    id: "amazon",
    nome: "Amazon",
    fonte: "settlement (repasse quinzenal, 2 postagens por ciclo)",
    integrado: false,
    nota: null,
  },
  {
    id: "shein",
    nome: "SHEIN",
    fonte: "check order / repasse semanal — já ingerido em shein_settlement",
    integrado: false,
    nota: null,
  },
  {
    id: "magalu",
    nome: "Magalu",
    fonte: "relatório financeiro do seller (repasse)",
    integrado: false,
    nota: null,
  },
  {
    id: "vendas-internas",
    nome: "B2B",
    fonte: "contas a receber da Omie (duplicatas/boletos)",
    integrado: false,
    nota: null,
  },
];

/** Hoje em BRT no formato 'YYYY-MM-DD' (dia de referência das faixas D+N). */
export function hojeBrt(): string {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" });
}

/** Roster completo como plataformas "ainda sem integração" (nenhum número inventado). */
export function recebiveisVazios(): RecebiveisPlataforma[] {
  return RECEBIVEIS_ROSTER.map((p) => ({
    ...p,
    total: null,
    disponivel: null,
    dias: [],
    atualizadoEm: null,
  }));
}
