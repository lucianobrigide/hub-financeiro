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
    // INTEGRADO 17/08/2026 (RPC shopee_recebiveis); cronograma PARCIAL com data
    // DERIVADA desde 19/08/2026 (decisão do Luciano). A Shopee NÃO publica a data
    // de liberação (investigação completa no CLAUDE.md), mas ela é derivável: o
    // escrow libera quando o pedido conclui — teto = entrega real + 7~8d (medido
    // em 14.434 pedidos, 99,40%). Valores 100% reais; só pedido ENTREGUE ganha
    // data (entrega + 8d); em trânsito/pré-envio fica em `valorSemData`. Detector
    // de acurácia 30d (piso 80%) suspende o cronograma sozinho se a régua driftar.
    // 22/08/2026 (pedido do Luciano: data em TODAS as plataformas): em trânsito →
    // coleta + 15d (entrega prevista coleta+7d, p90 medido, + 8d) e pré-envio →
    // venda + 18d (coleta prevista venda+3d + 15d); backtests 98,5% e 99,0% do
    // valor creditado até a data. Detector por camada.
    id: "shopee",
    nome: "Shopee",
    fonte: "escrow do pedido, conferido contra a carteira — data derivada: entregue = entrega + 8d · em trânsito = coleta + 15d · pré-envio = venda + 18d (tetos medidos, detector por camada)",
    integrado: false,
    nota: null,
  },
  {
    // INTEGRADO 17/08/2026 (RPC tt_recebiveis). Ficou FORA DO TOTAL de 17 a
    // 25/08 (o TikTok não informava data nem valor final do repasse). A DATA
    // virou derivada em 22/08 (statement DIÁRIO de entrega UTC + 7, 97,7%
    // não-otimista; coletado → coleta+14, pré-envio → venda+17). Em 25/08/2026
    // o Luciano decidiu a Opção B: o VALOR entra no total e na curva como
    // LÍQUIDO PROJETADO = bruto × razão móvel 60d (settlement/pago dos
    // liquidados, capada em 1.0), auto-corrigida pedido a pedido pelo
    // statement real. Base < 50 liquidados em 60d → volta ao bruto/fora do total.
    id: "tiktok",
    nome: "TikTok Shop",
    fonte: "líquido projetado (bruto × razão 60d dos liquidados, auto-corrigido pelo statement real) — data derivada do statement diário (entrega + 7d)",
    integrado: false,
    nota: null,
  },
  {
    // INTEGRADO 17/08/2026 (RPC az_recebiveis). Transferências a caminho têm data
    // real; o ciclo corrente (grupo Open) ganhou data DERIVADA em 22/08/2026: a
    // grade de 14 dias é fato da Amazon (abre/fecha toda 2ª 12:39 BRT; transfer
    // date = fechamento em 22/22 grupos; 94% do valor histórico fechou em 14d
    // exatos). Só ciclo aberto negativo fica sem data (abate o próximo).
    id: "amazon",
    nome: "Amazon",
    fonte: "ciclos financeiros da SP-API — transferências a caminho (data real) + ciclo corrente (data derivada da grade de 14 dias)",
    integrado: false,
    nota: null,
  },
  {
    // INTEGRADO 17/08/2026 (RPC shein_recebiveis). O check order traz
    // estimate_pay_time (data da PRÓPRIA SHEIN) e nasce na ENTREGA (status 5).
    // Pedido pré-entrega ganhou data DERIVADA em 22/08/2026: a regra de pagamento
    // da SHEIN é exata (2ª-feira 01:00 BRT, 2 semanas após a semana UTC+8 da
    // entrega — 118/118), aplicada a entrega prevista = envio + 12d (teto medido,
    // 98,3% não-otimista em 213 check orders). Detector 45d suspende sozinho.
    id: "shein",
    nome: "SHEIN",
    fonte: "check order com data da SHEIN (emitido na entrega) + pedidos pré-entrega com data derivada (regra semanal da SHEIN sobre envio + 12d)",
    integrado: false,
    nota: null,
  },
  {
    // INTEGRADO 17/08/2026 (RPC magalu_recebiveis), MVP. Sem cronograma: o Magalu
    // não publica data de repasse. A API de Análise Financeira (já autorizada) é
    // visão contábil por pedido, sem data de pagamento — e hoje vem vazia, porque
    // só cobre Entregue/Cancelado faturado e a operação tem 2 pedidos.
    id: "magalu",
    nome: "Magalu",
    fonte: "líquido real do pedido (bruto − comissão − frete) — o Magalu não publica data de repasse",
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
