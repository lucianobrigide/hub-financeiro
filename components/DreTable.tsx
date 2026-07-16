"use client";

import { COLORS, brl, pct } from "./ui";

/**
 * Estrutura da DRE — espelha a aba "DRE" do fechamento oficial (Essenza).
 * Todos os valores começam nulos ("— sem dados ainda"): vamos populando junto,
 * respeitando a regra de ouro do hub (sem dado real = null, nunca zero inventado).
 */
type Kind = "base" | "sub" | "child" | "total";

interface DreRow {
  label: string;
  op?: "=" | "−" | "+";
  code?: string; // I1, C6, R1...
  tag?: "F" | "V"; // Fixo / Variável (Grupo R)
  kind: Kind;
  valor: number | null; // R$ do mês de referência
  av: number | null; // Análise Vertical (% da Receita Bruta)
}

const r = (label: string, kind: Kind, extra: Partial<DreRow> = {}): DreRow => ({
  label,
  kind,
  valor: null,
  av: null,
  ...extra,
});

export const DRE_STRUCTURE: DreRow[] = [
  r("Receita Bruta", "base"),
  r("Vendas Canceladas", "sub", { op: "−" }),
  r("Venda Líquida", "total", { op: "=" }),

  r("Impostos s/ Vendas", "sub", { op: "−" }),
  r("DIFAL", "child", { op: "−", code: "I1" }),
  r("IPI", "child", { op: "−", code: "I2" }),
  r("Comissões/Fretes Marketplaces", "sub", { op: "−" }),
  r("Taxas de Cancelamento", "sub", { op: "−" }),
  r("Rebate Excedente", "sub", { op: "−", code: "C6" }),
  r("Receita Líquida", "total", { op: "=" }),

  r("CMV", "sub", { op: "−" }),
  r("Despesas com o Full", "sub", { op: "−", code: "C7" }),
  r("Fretes Vendas", "sub", { op: "−", code: "C2" }),
  r("Fornecedor s/ CP", "sub", { op: "−", code: "C3" }),
  r("Fornecedor Emb.", "sub", { op: "−", code: "C4" }),
  r("Marketing & Tráfego", "sub", { op: "−", code: "C1" }),
  r("Fixo_Combustível", "sub", { op: "−", code: "C5" }),
  r("Margem de Contribuição", "total", { op: "=" }),

  r("Fixo_Folha Salarial", "sub", { op: "−", code: "R1", tag: "F" }),
  r("Fixo_Estrutura Física", "sub", { op: "−", code: "R2", tag: "F" }),
  r("Fixo_Consultoria & Assessoria", "sub", { op: "−", code: "R3", tag: "F" }),
  r("Fixo_Servidores & Softwares", "sub", { op: "−", code: "R4", tag: "F" }),
  r("Fixo_Seguros", "sub", { op: "−", code: "R5", tag: "F" }),
  r("Fixo_Outros", "sub", { op: "−", code: "R6", tag: "F" }),
  r("Fixo_Combustível Adm", "sub", { op: "−", code: "R7", tag: "F" }),
  r("Fixo_Impostos Retidos 3º", "sub", { op: "−", code: "R8", tag: "F" }),
  r("Eventual_Folha Salarial", "sub", { op: "−", code: "R9", tag: "F" }),
  r("Eventual_Estrutura Física", "sub", { op: "−", code: "R10", tag: "V" }),
  r("Eventual_Consultoria & Assessoria", "sub", { op: "−", code: "R11", tag: "V" }),
  r("Eventual_Servidores & Softwares", "sub", { op: "−", code: "R12", tag: "V" }),
  r("Eventual_Cursos & Certificações", "sub", { op: "−", code: "R13", tag: "V" }),
  r("Eventual_Viagens", "sub", { op: "−", code: "R19", tag: "V" }),
  r("Eventual_Manutenção_Imobilizado", "sub", { op: "−", code: "R14", tag: "V" }),
  r("Eventual_Outros", "sub", { op: "−", code: "R15", tag: "V" }),
  r("Provisão", "total", { op: "=" }),

  r("Depreciação", "sub", { op: "−" }),
  r("Amortização dos Riscos", "sub", { op: "−" }),
  r("Amortização", "sub", { op: "−" }),
  r("Ebitda", "total", { op: "=" }),

  r("Receitas Financeiras", "sub", { op: "+", code: "R16" }),
  r("Despesas Financeiras", "sub", { op: "−", code: "R17" }),
  r("Ebit", "total", { op: "=" }),

  r("Ativo_Imobilizado", "sub", { op: "−", code: "R18" }),
  r("Dividendos", "sub", { op: "−", code: "R20" }),
  r("Resultado Líquido", "total", { op: "=" }),
];

function mesReferencia(): string {
  // Último mês FECHADO (mês anterior ao corrente), fuso SP.
  const hojeSP = new Date().toLocaleDateString("en-CA", {
    timeZone: "America/Sao_Paulo",
  });
  const [y, m] = hojeSP.split("-").map(Number);
  const ref = new Date(Date.UTC(y, m - 2, 1)); // m-2: mês anterior (m é 1-based)
  return ref
    .toLocaleDateString("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" })
    .replace(/^\w/, (c) => c.toUpperCase());
}

function Cell({ value, render }: { value: number | null; render: (v: number) => string }) {
  if (value == null) {
    return (
      <span className="text-[10px] italic" style={{ color: COLORS.muted }}>
        —
      </span>
    );
  }
  return <span>{render(value)}</span>;
}

export function DreTable() {
  const mes = mesReferencia();

  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr style={{ color: COLORS.muted }}>
            <th className="w-8 py-2 text-left text-[10px] font-semibold uppercase tracking-wider" />
            <th className="py-2 text-left text-[10px] font-semibold uppercase tracking-wider">
              Conta
            </th>
            <th className="w-16 py-2 text-right text-[10px] font-semibold uppercase tracking-wider">
              Cód.
            </th>
            <th className="w-40 py-2 text-right text-[10px] font-semibold uppercase tracking-wider">
              {mes}
            </th>
            <th className="w-20 py-2 text-right text-[10px] font-semibold uppercase tracking-wider">
              AV %
            </th>
          </tr>
        </thead>
        <tbody>
          {DRE_STRUCTURE.map((row, i) => {
            const isTotal = row.kind === "total";
            const isBase = row.kind === "base";
            const isChild = row.kind === "child";
            return (
              <tr
                key={row.label + i}
                style={{
                  borderTop: isTotal ? `1px solid ${COLORS.panelBorder}` : undefined,
                  background: isTotal ? `${COLORS.cyan}0a` : undefined,
                }}
              >
                <td
                  className="py-1.5 text-center text-xs font-bold"
                  style={{ color: row.op === "=" ? COLORS.cyan : COLORS.muted }}
                >
                  {row.op ?? ""}
                </td>
                <td
                  className="py-1.5"
                  style={{
                    paddingLeft: isChild ? 24 : isBase || isTotal ? 0 : 8,
                    color: isTotal || isBase ? COLORS.white : COLORS.muted,
                    fontWeight: isTotal || isBase ? 700 : 400,
                    fontSize: isChild ? 12 : undefined,
                  }}
                >
                  {row.label}
                  {row.tag && (
                    <span
                      className="ml-2 rounded px-1 text-[9px] font-semibold"
                      style={{
                        color: row.tag === "F" ? COLORS.cyan : COLORS.green,
                        border: `1px solid ${row.tag === "F" ? COLORS.cyan : COLORS.green}55`,
                      }}
                    >
                      {row.tag}
                    </span>
                  )}
                </td>
                <td className="py-1.5 text-right text-[10px]" style={{ color: COLORS.muted }}>
                  {row.code ?? ""}
                </td>
                <td
                  className="py-1.5 text-right tabular-nums"
                  style={{
                    color: isTotal || isBase ? COLORS.white : COLORS.muted,
                    fontWeight: isTotal || isBase ? 700 : 400,
                  }}
                >
                  <Cell value={row.valor} render={brl} />
                </td>
                <td className="py-1.5 text-right tabular-nums" style={{ color: COLORS.muted }}>
                  <Cell value={row.av} render={pct} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      <div className="mt-4 flex flex-wrap gap-4 text-[11px]" style={{ color: COLORS.muted }}>
        <span>
          <span className="mr-1 font-semibold" style={{ color: COLORS.cyan }}>
            F
          </span>
          Despesas Fixas
        </span>
        <span>
          <span className="mr-1 font-semibold" style={{ color: COLORS.green }}>
            V
          </span>
          Despesas Variáveis
        </span>
        <span>Grupo R — Rateios (folha, estrutura, financeiras, etc.)</span>
      </div>
    </div>
  );
}
