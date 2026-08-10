"use client";

import { Fragment, useEffect, useState, type ChangeEvent } from "react";
import { fetchDreCompletoAction, fetchDreDriftAction, fetchDreItensAction } from "@/app/actions";
import type { DreDrift, DreItem } from "@/lib/data/types";
import { useDashboard } from "./DashboardProvider";
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
}

const r = (label: string, kind: Kind, extra: Partial<DreRow> = {}): DreRow => ({
  label,
  kind,
  valor: null,
  ...extra,
});

export const DRE_STRUCTURE: DreRow[] = [
  r("Receita Bruta", "base"),
  r("Vendas Canceladas", "sub", { op: "−" }),
  r("Venda Líquida", "total", { op: "=" }),

  r("Impostos s/ Vendas", "sub", { op: "−" }),
  r("DIFAL", "child", { op: "−", code: "I1" }),
  r("IPI", "child", { op: "−", code: "I2" }),
  r("PIS", "child", { op: "−", code: "I3" }),
  r("COFINS", "child", { op: "−", code: "I4" }),
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

/** 'YYYY-MM' do mês corrente (fuso SP) — todo mês anterior a ele está fechado. */
function mesCorrenteValue(): string {
  return new Date().toLocaleDateString("en-CA", { timeZone: "America/Sao_Paulo" }).slice(0, 7);
}

/** Rótulo pt-BR ("Junho 2026") a partir de 'YYYY-MM' — fallback quando o mês não está na lista. */
function labelMes(value: string): string {
  const [y, m] = value.split("-").map(Number);
  return new Date(Date.UTC(y, (m ?? 1) - 1, 1))
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
  // Meses fechados (< mês corrente), mais recente primeiro — lista vem do provider do hub.
  // O DRE tem seletor próprio porque a régua dele é "só mês fechado"; o seletor global
  // do topo inclui o mês em andamento e não vale aqui.
  const { months } = useDashboard();
  const mesesFechados = months.filter((m) => m.value < mesCorrenteValue());
  const [mesSelecionado, setMesSelecionado] = useState<string | null>(null);
  const mesValue = mesSelecionado ?? mesesFechados[0]?.value ?? "";
  const mes = mesesFechados.find((m) => m.value === mesValue)?.label ?? (mesValue ? labelMes(mesValue) : "—");
  // DRE do mês fechado: topo (Hub, acima da MC, por rótulo) + subcategorias do Grupo R
  // (Omie, por código). Clique numa linha com detalhe p/ abrir/fechar.
  const [topo, setTopo] = useState<Record<string, number>>({});
  const [detalhe, setDetalhe] = useState<Record<string, { nome: string; valor: number }[]>>({});
  const [aberto, setAberto] = useState<Set<string>>(new Set());
  // 3º nível: itens unitários por (linha|categoria), buscados sob demanda ao clicar na categoria.
  const [abertoItem, setAbertoItem] = useState<Set<string>>(new Set());
  const [itens, setItens] = useState<Record<string, DreItem[]>>({});
  // Trava de fechamento: selo "fechado ✓ / divergente ⚠" do mês selecionado.
  const [drift, setDrift] = useState<DreDrift | null>(null);
  const [driftAberto, setDriftAberto] = useState(false);

  useEffect(() => {
    if (!mesValue) return;
    let ativo = true;
    // Troca de mês: zera o drill-down (o cache de itens é por linha|categoria, sem mês).
    setAberto(new Set());
    setAbertoItem(new Set());
    setItens({});
    fetchDreCompletoAction(mesValue).then(({ topo: t, detalhe: rows }) => {
      if (!ativo) return;
      setTopo(t ?? {});
      const g: Record<string, { nome: string; valor: number }[]> = {};
      for (const rr of rows) (g[rr.dre_code] ??= []).push({ nome: rr.nome, valor: rr.valor });
      setDetalhe(g);
    });
    setDrift(null);
    setDriftAberto(false);
    fetchDreDriftAction(mesValue).then((d) => {
      if (ativo) setDrift(d);
    });
    return () => {
      ativo = false;
    };
  }, [mesValue]);

  const toggle = (code: string) =>
    setAberto((s) => {
      const n = new Set(s);
      if (n.has(code)) n.delete(code);
      else n.add(code);
      return n;
    });

  // Abre/fecha os itens unitários de uma categoria; busca sob demanda (cache por chave).
  const toggleItem = (code: string, cat: string) => {
    const key = `${code}|${cat}`;
    setAbertoItem((s) => {
      const n = new Set(s);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });
    if (!itens[key]) {
      fetchDreItensAction(mesValue, code, cat).then((list) =>
        setItens((prev) => ({ ...prev, [key]: list ?? [] })),
      );
    }
  };

  // Pass 1 — valor "próprio" bruto: subcategorias (Omie) somadas; senão topo do Hub (por
  // rótulo); senão null ("—").
  const own: (number | null)[] = DRE_STRUCTURE.map((row) => {
    const filhos = row.code ? detalhe[row.code] : undefined;
    if (filhos && filhos.length) return filhos.reduce((s, f) => s + f.valor, 0);
    if (row.label in topo) return topo[row.label];
    return row.valor;
  });
  // Pass 2 — um "sub" seguido de linhas "child" (ex.: Impostos → DIFAL/IPI) vale a soma delas.
  DRE_STRUCTURE.forEach((row, i) => {
    if (row.kind !== "sub") return;
    const kids: number[] = [];
    for (let j = i + 1; j < DRE_STRUCTURE.length && DRE_STRUCTURE[j].kind === "child"; j++) kids.push(j);
    if (kids.length && kids.some((j) => own[j] != null)) own[i] = kids.reduce((s, j) => s + (own[j] ?? 0), 0);
  });

  // Cascateamento: acumula os "sub" (− ou +) a partir da "base"; "total" mostra o acumulado;
  // "child" é só exibição (a soma entra pelo "sub" pai). Linha "—" conta 0.
  const display: (number | null)[] = [];
  {
    let acc = 0;
    DRE_STRUCTURE.forEach((row, i) => {
      const v = own[i];
      if (row.kind === "base") {
        acc = v ?? 0;
        display[i] = acc;
      } else if (row.kind === "total") {
        display[i] = acc;
      } else if (row.kind === "child") {
        display[i] = v;
      } else {
        acc += row.op === "+" ? (v ?? 0) : -(v ?? 0);
        display[i] = v;
      }
    });
  }

  // AV (Análise Vertical) — cada linha como % da Receita Bruta do mês.
  const receitaBruta = display[0];
  const av = (v: number | null): number | null =>
    v == null || receitaBruta == null || receitaBruta <= 0 ? null : (v / receitaBruta) * 100;

  return (
    <div className="overflow-x-auto">
      <div className="mb-3 flex items-center justify-end gap-3">
        {/* Selo da trava de fechamento: compara o DRE vivo com o snapshot congelado. */}
        {drift &&
          (!drift.fechado ? (
            <span className="rounded-full border px-2.5 py-1 text-[10px]" style={{ color: COLORS.muted, borderColor: COLORS.panelBorder }}>
              sem fechamento registrado
            </span>
          ) : (drift.drift_total ?? 0) === 0 && (drift.linhas_divergentes?.length ?? 0) === 0 ? (
            <span
              className="rounded-full px-2.5 py-1 text-[10px] font-semibold"
              style={{ color: COLORS.green, background: `${COLORS.green}1a` }}
              title={drift.obs ?? undefined}
            >
              ✓ Fechado em {drift.fechado_em} — sem divergências
            </span>
          ) : (
            <button
              type="button"
              onClick={() => setDriftAberto((v) => !v)}
              className="rounded-full px-2.5 py-1 text-[10px] font-bold"
              style={{ color: COLORS.red, background: `${COLORS.red}1a`, cursor: "pointer" }}
              title="O DRE vivo divergiu do fechamento oficial — clique para ver as linhas"
            >
              ⚠ DIVERGENTE do fechamento ({drift.fechado_em}) · Δ {brl(drift.drift_total ?? 0)}{" "}
              {driftAberto ? "▾" : "▸"}
            </button>
          ))}
        <span className="text-xs" style={{ color: COLORS.muted }}>
          Mês fechado
        </span>
        <select
          aria-label="Selecionar mês fechado"
          value={mesValue}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => setMesSelecionado(e.target.value)}
          disabled={mesesFechados.length === 0}
          className="rounded-lg border px-3 py-2 text-sm font-medium outline-none disabled:opacity-60"
          style={{ background: COLORS.panel, borderColor: COLORS.panelBorder, color: COLORS.white }}
        >
          {mesesFechados.length === 0 && <option value="">Sem mês fechado</option>}
          {mesesFechados.map((m) => (
            <option key={m.value} value={m.value} style={{ background: COLORS.panel }}>
              {m.label}
            </option>
          ))}
        </select>
      </div>
      {/* Detalhe da divergência: linha a linha, fechado × atual. */}
      {driftAberto && drift?.fechado && (drift.linhas_divergentes?.length ?? 0) > 0 && (
        <div className="mb-3 rounded-lg border p-3" style={{ borderColor: `${COLORS.red}55`, background: `${COLORS.red}0a` }}>
          <div className="mb-2 text-[11px] font-semibold" style={{ color: COLORS.red }}>
            O DRE vivo divergiu do fechamento oficial — alguém remarcou lançamentos deste mês na Omie:
          </div>
          <table className="w-full text-[11px]">
            <thead>
              <tr style={{ color: COLORS.muted }}>
                <th className="py-1 text-left font-semibold">Linha</th>
                <th className="py-1 text-right font-semibold">Fechado</th>
                <th className="py-1 text-right font-semibold">Atual</th>
                <th className="py-1 text-right font-semibold">Δ</th>
              </tr>
            </thead>
            <tbody>
              {drift.linhas_divergentes!.map((d) => (
                <tr key={d.linha}>
                  <td className="py-0.5" style={{ color: COLORS.white }}>{d.linha}</td>
                  <td className="py-0.5 text-right tabular-nums" style={{ color: COLORS.muted }}>{brl(d.fechado)}</td>
                  <td className="py-0.5 text-right tabular-nums" style={{ color: COLORS.muted }}>{brl(d.atual)}</td>
                  <td className="py-0.5 text-right font-semibold tabular-nums" style={{ color: COLORS.red }}>{brl(d.delta)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="mt-2 text-[10px]" style={{ color: COLORS.muted }}>
            Corrija na Omie (o número volta sozinho no próximo sync) ou re-feche o mês para aceitar o novo valor.
          </div>
        </div>
      )}
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
            const filhos = row.code ? detalhe[row.code] : undefined;
            const temDetalhe = !!filhos && filhos.length > 0;
            const valor = display[i];
            const estaAberto = temDetalhe && row.code ? aberto.has(row.code) : false;
            // Esconde linhas sem despesa no mês (mantém Receita/base e os totais da cascata).
            if (!isTotal && !isBase && valor == null) return null;
            return (
              <Fragment key={row.label + i}>
                <tr
                  onClick={temDetalhe && row.code ? () => toggle(row.code!) : undefined}
                  style={{
                    borderTop: isTotal ? `1px solid ${COLORS.panelBorder}` : undefined,
                    background: isTotal ? `${COLORS.cyan}0a` : undefined,
                    cursor: temDetalhe ? "pointer" : undefined,
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
                    {temDetalhe && (
                      <span className="mr-1 inline-block w-2 text-[9px]" style={{ color: COLORS.cyan }}>
                        {estaAberto ? "▾" : "▸"}
                      </span>
                    )}
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
                    <Cell value={valor} render={brl} />
                  </td>
                  <td
                    className="py-1.5 text-right tabular-nums"
                    style={{
                      color: isTotal || isBase ? COLORS.white : COLORS.muted,
                      fontWeight: isTotal || isBase ? 700 : 400,
                    }}
                  >
                    <Cell value={av(valor)} render={pct} />
                  </td>
                </tr>
                {estaAberto &&
                  filhos!.map((f, j) => {
                    const catKey = `${row.code}|${f.nome}`;
                    const itemAberto = abertoItem.has(catKey);
                    const lista = itens[catKey];
                    return (
                      <Fragment key={`${row.label}${i}-sub${j}`}>
                        <tr
                          onClick={row.code ? () => toggleItem(row.code!, f.nome) : undefined}
                          style={{ background: `${COLORS.cyan}06`, cursor: "pointer" }}
                        >
                          <td />
                          <td className="py-1 text-[11px]" style={{ paddingLeft: 34, color: COLORS.muted }}>
                            <span className="mr-1 inline-block w-2 text-[9px]" style={{ color: COLORS.cyan }}>
                              {itemAberto ? "▾" : "▸"}
                            </span>
                            {f.nome}
                          </td>
                          <td />
                          <td className="py-1 text-right text-[11px] tabular-nums" style={{ color: COLORS.muted }}>
                            {brl(f.valor)}
                          </td>
                          <td className="py-1 text-right text-[11px] tabular-nums" style={{ color: COLORS.muted }}>
                            {av(f.valor) != null ? pct(av(f.valor)!) : ""}
                          </td>
                        </tr>
                        {itemAberto &&
                          (lista === undefined ? (
                            <tr style={{ background: `${COLORS.cyan}03` }}>
                              <td />
                              <td className="py-1 text-[10px] italic" style={{ paddingLeft: 48, color: COLORS.muted }}>
                                carregando…
                              </td>
                              <td />
                              <td />
                              <td />
                            </tr>
                          ) : (
                            lista.map((it, k) => (
                              <tr key={`${catKey}-${k}`} style={{ background: `${COLORS.cyan}03` }}>
                                <td />
                                <td className="py-1 text-[10px]" style={{ paddingLeft: 48, color: COLORS.muted }}>
                                  {it.fornecedor}
                                  <span className="ml-2 text-[9px]" style={{ color: COLORS.muted, opacity: 0.7 }}>
                                    {it.data} · {it.fonte}
                                    {it.doc ? ` · ${it.doc}` : ""}
                                  </span>
                                </td>
                                <td />
                                <td className="py-1 text-right text-[10px] tabular-nums" style={{ color: COLORS.muted }}>
                                  {brl(it.valor)}
                                </td>
                                <td className="py-1 text-right text-[10px] tabular-nums" style={{ color: COLORS.muted, opacity: 0.7 }}>
                                  {av(it.valor) != null ? pct(av(it.valor)!) : ""}
                                </td>
                              </tr>
                            ))
                          ))}
                      </Fragment>
                    );
                  })}
              </Fragment>
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
