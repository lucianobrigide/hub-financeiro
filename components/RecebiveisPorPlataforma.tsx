"use client";

import { useState } from "react";
import type { Recebiveis, RecebiveisPlataforma } from "@/lib/data/types";
import { COLORS, Panel, brl } from "./ui";

/**
 * Seção "Recebíveis por plataforma" (aba F.C. Projetado).
 *
 * Responde: quanto cada plataforma ainda me deve e em que dia esse dinheiro cai.
 *
 * REGRA DURA: plataforma sem integração NÃO exibe número — exibe "aguardando
 * integração". O total geral só soma as integradas e vem sempre acompanhado da
 * cobertura ("2 de 7 plataformas"), pra ninguém ler o número como o caixa inteiro.
 */

/** Faixas do cronograma, em dias corridos a partir da referência. */
const FAIXAS: { label: string; ate: number | null }[] = [
  { label: "Até 7 dias", ate: 7 },
  { label: "8 a 15 dias", ate: 15 },
  { label: "16 a 30 dias", ate: 30 },
  { label: "Mais de 30 dias", ate: null },
];

/** Diferença em dias corridos entre duas datas 'YYYY-MM-DD' (sem fuso: ambas viram UTC). */
function difDias(de: string, ate: string): number {
  const a = Date.parse(`${de}T00:00:00Z`);
  const b = Date.parse(`${ate}T00:00:00Z`);
  return Math.round((b - a) / 86400000);
}

/** Σ por faixa. Dias já vencidos (d <= 0) caem na primeira faixa. */
function porFaixa(p: RecebiveisPlataforma, referencia: string): number[] {
  const out = FAIXAS.map(() => 0);
  for (const d of p.dias) {
    const n = difDias(referencia, d.data);
    const i = FAIXAS.findIndex((f) => f.ate == null || n <= f.ate);
    out[i === -1 ? FAIXAS.length - 1 : i] += d.valor;
  }
  return out;
}

/** "17/08" a partir de 'YYYY-MM-DD'. */
function ddmm(data: string): string {
  const [, m, d] = data.split("-");
  return `${d}/${m}`;
}

function Tag({ cor, children }: { cor: string; children: React.ReactNode }) {
  return (
    <span
      className="rounded-full border px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wider"
      style={{ color: cor, borderColor: `${cor}55`, background: `${cor}12` }}
    >
      {children}
    </span>
  );
}

function CardPlataforma({
  p,
  referencia,
}: {
  p: RecebiveisPlataforma;
  referencia: string;
}) {
  const [aberto, setAberto] = useState(false);
  const faixas = p.integrado ? porFaixa(p, referencia) : null;

  return (
    <div
      className="rounded-xl border p-4"
      style={{
        background: COLORS.bg,
        borderColor: p.integrado ? COLORS.panelBorder : `${COLORS.panelBorder}`,
        opacity: p.integrado ? 1 : 0.75,
      }}
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h3 className="text-sm font-bold text-white">{p.nome}</h3>
            {p.integrado ? (
              <Tag cor={COLORS.green}>integrado</Tag>
            ) : (
              <Tag cor={COLORS.muted}>aguardando integração</Tag>
            )}
          </div>
          <p className="mt-1 text-xs" style={{ color: COLORS.muted }}>
            {p.fonte}
          </p>
        </div>
        <div className="text-right">
          <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
            A receber
          </div>
          {p.total == null ? (
            <div className="text-sm italic" style={{ color: COLORS.muted }}>
              — sem dados ainda
            </div>
          ) : (
            <div className="text-lg font-bold" style={{ color: COLORS.cyan }}>
              {brl(p.total)}
            </div>
          )}
        </div>
      </div>

      {faixas && (
        <>
          <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
            {FAIXAS.map((f, i) => (
              <div
                key={f.label}
                className="rounded-lg border px-2 py-1.5 text-center"
                style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}
              >
                <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
                  {f.label}
                </div>
                <div
                  className="text-sm font-semibold"
                  style={{ color: faixas[i] > 0 ? COLORS.white : COLORS.muted }}
                >
                  {brl(faixas[i])}
                </div>
              </div>
            ))}
          </div>

          <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs">
            <span style={{ color: COLORS.muted }}>
              {p.disponivel != null && (
                <>
                  Já liberado na conta:{" "}
                  <strong style={{ color: COLORS.green }}>{brl(p.disponivel)}</strong>
                  {" · "}
                </>
              )}
              {p.dias.length} {p.dias.length === 1 ? "data" : "datas"} de liberação
              {p.atualizadoEm ? ` · atualizado ${p.atualizadoEm}` : ""}
            </span>
            {p.dias.length > 0 && (
              <button
                type="button"
                onClick={() => setAberto((o) => !o)}
                className="rounded-lg border px-2 py-1 transition-colors"
                style={{ color: COLORS.cyan, borderColor: `${COLORS.cyan}44` }}
              >
                {aberto ? "Ocultar cronograma" : "Ver cronograma"}
              </button>
            )}
          </div>

          {aberto && (
            <ul className="mt-3 space-y-1 border-t pt-3" style={{ borderColor: COLORS.panelBorder }}>
              {p.dias.map((d) => (
                <li key={d.data} className="flex justify-between text-xs">
                  <span style={{ color: COLORS.muted }}>
                    {ddmm(d.data)}{" "}
                    <span className="opacity-60">
                      (D+{Math.max(difDias(referencia, d.data), 0)})
                    </span>
                  </span>
                  <span className="font-semibold text-white">{brl(d.valor)}</span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}

      {p.nota && (
        <p className="mt-3 text-xs italic" style={{ color: COLORS.muted }}>
          {p.nota}
        </p>
      )}
    </div>
  );
}

export function RecebiveisPorPlataforma({ dados }: { dados: Recebiveis | null }) {
  if (!dados) {
    return (
      <Panel title="Recebíveis por plataforma">
        <p className="text-sm italic" style={{ color: COLORS.muted }}>
          — sem dados ainda
        </p>
      </Panel>
    );
  }

  const { referencia, plataformas } = dados;
  const integradas = plataformas.filter((p) => p.integrado);
  const totalGeral = integradas.reduce((s, p) => s + (p.total ?? 0), 0);
  const dispGeral = integradas.reduce((s, p) => s + (p.disponivel ?? 0), 0);
  // Faixas consolidadas — só das integradas (o resto não tem número).
  const faixasGerais = FAIXAS.map((_, i) =>
    integradas.reduce((s, p) => s + porFaixa(p, referencia)[i], 0),
  );

  return (
    <Panel title="Recebíveis por plataforma">
      <div
        className="rounded-xl border p-4"
        style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}
      >
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              Total a receber (plataformas integradas)
            </div>
            {integradas.length === 0 ? (
              <div className="text-lg italic" style={{ color: COLORS.muted }}>
                — sem dados ainda
              </div>
            ) : (
              <div className="text-2xl font-bold" style={{ color: COLORS.cyan }}>
                {brl(totalGeral)}
              </div>
            )}
          </div>
          <div className="text-right text-xs" style={{ color: COLORS.muted }}>
            <div>
              cobertura:{" "}
              <strong style={{ color: integradas.length ? COLORS.white : COLORS.muted }}>
                {integradas.length} de {plataformas.length} plataformas
              </strong>
            </div>
            <div>referência: {ddmm(referencia)}</div>
            {dispGeral > 0 && (
              <div>
                já liberado: <strong style={{ color: COLORS.green }}>{brl(dispGeral)}</strong>
              </div>
            )}
          </div>
        </div>

        {integradas.length > 0 && (
          <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
            {FAIXAS.map((f, i) => (
              <div
                key={f.label}
                className="rounded-lg border px-2 py-1.5 text-center"
                style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}
              >
                <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
                  {f.label}
                </div>
                <div className="text-sm font-semibold text-white">{brl(faixasGerais[i])}</div>
              </div>
            ))}
          </div>
        )}

        <p className="mt-3 text-xs italic" style={{ color: COLORS.muted }}>
          O total soma apenas as plataformas já integradas — não é o caixa a receber
          inteiro enquanto a cobertura não for {plataformas.length} de {plataformas.length}.
        </p>
      </div>

      <div className="mt-3 space-y-3">
        {plataformas.map((p) => (
          <CardPlataforma key={p.id} p={p} referencia={referencia} />
        ))}
      </div>
    </Panel>
  );
}
