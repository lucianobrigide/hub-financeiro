"use client";

import { useState } from "react";
import type { SaidaHistoricoTitulo, SaidasProjetadas as SaidasProjetadasData, SaidaTitulo } from "@/lib/data/types";
import { COLORS, Panel, brl } from "./ui";

/**
 * Seção "Saídas projetadas" (aba F.C. Projetado).
 *
 * Responde: quanto já está LANÇADO na Omie para sair, e em que dia vence.
 *
 * Datas pela PREVISÃO DE PAGAMENTO da Omie (decisão do Luciano 25/08/2026 —
 * é a data que o financeiro programa; fallback: vencimento). Três baldes,
 * separados de propósito (corte FIXO em ago/2026 — decisão do Luciano
 * 25/08/2026: "considerar o contas a pagar a partir de agosto, ou projetado"):
 *  • com data (próximos 90 dias) — o cronograma;
 *  • previsto desde ago/2026 e não pago — exigível agora, entra no total
 *    até ser baixado na Omie (o corte não desliza com o tempo);
 *  • previsto antes de ago/2026 — legado que nunca foi baixado na Omie; NÃO é
 *    saída futura, fica FORA do total por decisão, mas visível por fornecedor.
 * REGRA DURA: nada estimado — e o que a Omie ainda não tem lançado (folha futura,
 * impostos a apurar, boletos que ainda não chegaram) NÃO aparece. A nota diz isso.
 *
 * PASSADO (26/08/2026, pedido do Luciano): os dias que passaram não somem do
 * cronograma — ficam no topo (desde o corte ago/2026) mostrando o que estava
 * PREVISTO no dia e o status real de cada título: pago (baixado na Omie) ou em
 * aberto (segue no exigível D+0). A Omie não devolve a data da baixa, então
 * "pago" é status, não prova de que saiu naquele dia exato — a nota diz isso.
 */

const AMBER = "#ffb84d";

const FAIXAS: { label: string; ate: number | null }[] = [
  { label: "Até 7 dias", ate: 7 },
  { label: "8 a 15 dias", ate: 15 },
  { label: "16 a 30 dias", ate: 30 },
  { label: "31 a 90 dias", ate: null },
];

function difDias(de: string, ate: string): number {
  const a = Date.parse(`${de}T00:00:00Z`);
  const b = Date.parse(`${ate}T00:00:00Z`);
  return Math.round((b - a) / 86400000);
}

function ddmm(data: string): string {
  const [, m, d] = data.split("-");
  return `${d}/${m}`;
}

function Barra({ frac, cor = COLORS.red }: { frac: number; cor?: string }) {
  const f = Math.max(0, Math.min(1, Number.isFinite(frac) ? frac : 0));
  return (
    <div className="h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
      <div
        className="h-full rounded-full"
        style={{ width: f > 0 ? `max(2px, ${(f * 100).toFixed(2)}%)` : 0, background: cor }}
      />
    </div>
  );
}

function Kpi({
  label,
  valor,
  cor,
  sub,
}: {
  label: string;
  valor: string;
  cor: string;
  sub?: string;
}) {
  return (
    <div className="rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
      <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
        {label}
      </div>
      <div className="text-base font-bold" style={{ color: cor }}>
        {valor}
      </div>
      {sub && (
        <div className="text-[11px]" style={{ color: COLORS.muted }}>
          {sub}
        </div>
      )}
    </div>
  );
}

/** Lista de títulos de um dia PASSADO: cada título com o status real (pago / em aberto). */
function TitulosHistorico({ itens }: { itens: SaidaHistoricoTitulo[] }) {
  return (
    <ul className="my-1 space-y-1 rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
      {itens.map((t, i) => (
        <li key={i} className="flex items-baseline gap-2 text-[11px]">
          <span className="w-[64px] shrink-0" style={{ color: t.pago ? COLORS.green : AMBER }}>
            {t.pago ? "✓ pago" : "em aberto"}
          </span>
          <span className="min-w-0 flex-1 truncate text-white">{t.fornecedor}</span>
          <span className="hidden shrink-0 sm:inline" style={{ color: COLORS.muted }}>
            {t.grupo}
            {t.doc ? ` · ${t.doc}` : ""}
            {t.parcela && t.parcela !== "001/001" ? ` · parc. ${t.parcela}` : ""}
            {t.venc !== t.prev ? ` · venc. ${ddmm(t.venc)}` : ""}
          </span>
          <span className="w-[90px] shrink-0 text-right tabular-nums text-white">{brl(t.valor)}</span>
        </li>
      ))}
    </ul>
  );
}

/** Lista de títulos de um dia (abre ao clicar na linha do cronograma). Datas = previsão de pagamento. */
function Titulos({ itens, mostrarData = false }: { itens: SaidaTitulo[]; mostrarData?: boolean }) {
  return (
    <ul className="my-1 space-y-1 rounded-lg border px-3 py-2" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
      {itens.map((t, i) => (
        <li key={i} className="flex items-baseline gap-2 text-[11px]">
          {mostrarData && (
            <span className="w-[38px] shrink-0 tabular-nums" style={{ color: AMBER }}>
              {ddmm(t.prev)}
            </span>
          )}
          <span className="min-w-0 flex-1 truncate text-white">{t.fornecedor}</span>
          <span className="hidden shrink-0 sm:inline" style={{ color: COLORS.muted }}>
            {t.grupo}
            {t.doc ? ` · ${t.doc}` : ""}
            {t.parcela && t.parcela !== "001/001" ? ` · parc. ${t.parcela}` : ""}
            {t.venc !== t.prev ? ` · venc. ${ddmm(t.venc)}` : ""}
          </span>
          <span className="w-[90px] shrink-0 text-right tabular-nums text-white">{brl(t.valor)}</span>
        </li>
      ))}
    </ul>
  );
}

export function SaidasProjetadas({ dados }: { dados: SaidasProjetadasData | null }) {
  const [cronogramaAberto, setCronogramaAberto] = useState(false);
  const [antigoAberto, setAntigoAberto] = useState(false);
  // Dia expandido no cronograma ("vencido" = a linha do exigível em D+0).
  const [diaAberto, setDiaAberto] = useState<string | null>(null);

  if (!dados) {
    return (
      <Panel title="Saídas projetadas (Omie — contas a pagar)">
        <p className="text-sm italic" style={{ color: COLORS.muted }}>
          — sem dados ainda
        </p>
      </Panel>
    );
  }

  const { referencia } = dados;
  const faixas = FAIXAS.map(() => 0);
  for (const d of dados.dias) {
    const n = difDias(referencia, d.data);
    const i = FAIXAS.findIndex((f) => f.ate == null || n <= f.ate);
    faixas[i === -1 ? FAIXAS.length - 1 : i] += d.valor;
  }
  const somaFaixas = faixas.reduce((s, v) => s + v, 0);
  // Passado: dias já ocorridos do cronograma (desde o corte), previsto + status real.
  const historico = dados.historico ?? [];
  const maiorDia = Math.max(
    dados.dias.reduce((m, d) => Math.max(m, d.valor), 0),
    historico.reduce((m, h) => Math.max(m, h.pago + h.aberto), 0),
  );
  const grupos = dados.grupos.filter((g) => g.valor90d > 0 || g.vencidoRecente > 0);
  const maiorGrupo = grupos.reduce((m, g) => Math.max(m, g.valor90d + g.vencidoRecente), 0);
  // "A pagar" = o que tem data nos 90 dias + o vencido recente (exigível agora).
  const aPagar = dados.comData90d + dados.vencidoRecente.valor;

  return (
    <Panel title="Saídas projetadas (Omie — contas a pagar)">
      <div className="rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
        <div className="flex flex-wrap items-end justify-between gap-3">
          <div>
            <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              A pagar — lançado na Omie (próximos 90 dias + vencido recente)
            </div>
            <div className="text-2xl font-bold" style={{ color: COLORS.red }}>
              {brl(aPagar)}
            </div>
          </div>
          <div className="text-right text-xs" style={{ color: COLORS.muted }}>
            <div>
              {dados.titulosComData} títulos em aberto com pagamento previsto de hoje em diante · referência {ddmm(referencia)}
            </div>
            {dados.atualizadoEm && <div>contas a pagar sincronizadas {dados.atualizadoEm}</div>}
          </div>
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
          <Kpi label="Com data (90 dias)" valor={brl(dados.comData90d)} cor={COLORS.white} sub={`${dados.dias.length} datas de pagamento previstas`} />
          <Kpi
            label="Previsto e não pago (ago/26+)"
            valor={brl(dados.vencidoRecente.valor)}
            cor={AMBER}
            sub={
              dados.vencidoRecente.titulos > 0
                ? `${dados.vencidoRecente.titulos} títulos sem baixa, desde ${dados.vencidoRecente.desde ? ddmm(dados.vencidoRecente.desde) : "—"} — exigível agora`
                : "nenhum"
            }
          />
          <Kpi
            label="Após 90 dias"
            valor={brl(dados.apos90d.valor)}
            cor={COLORS.muted}
            sub={dados.apos90d.titulos > 0 ? `${dados.apos90d.titulos} títulos até ${dados.apos90d.ate ? ddmm(dados.apos90d.ate) + "/" + dados.apos90d.ate.slice(0, 4) : "—"} (fora do horizonte)` : "nenhum"}
          />
          <Kpi
            label="Vencido pré-ago/26 — fora"
            valor={brl(dados.vencidoAntigo.valor)}
            cor={COLORS.muted}
            sub={`${dados.vencidoAntigo.titulos} títulos nunca baixados — não entram (decisão 25/08)`}
          />
        </div>

        <div className="mt-3 grid grid-cols-2 gap-2 sm:grid-cols-4">
          {FAIXAS.map((f, i) => (
            <div key={f.label} className="rounded-lg border px-2 py-1.5" style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}>
              <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
                {f.label}
              </div>
              <div className="mb-1.5 text-sm font-semibold" style={{ color: faixas[i] > 0 ? COLORS.white : COLORS.muted }}>
                {brl(faixas[i])}
              </div>
              <Barra frac={somaFaixas > 0 ? faixas[i] / somaFaixas : 0} />
            </div>
          ))}
        </div>

        <p className="mt-3 text-xs italic" style={{ color: COLORS.muted }}>
          Só o que já está <strong style={{ color: COLORS.white }}>lançado</strong> na Omie (contas a pagar em
          aberto, pela previsão de pagamento da Omie). Despesa que ainda não virou título — folha do mês que vem,
          impostos a apurar, boleto que ainda não chegou — <strong style={{ color: COLORS.white }}>não aparece</strong>.
          Contas a pagar contam <strong style={{ color: COLORS.white }}>a partir de ago/2026</strong> (decisão de
          25/08/2026): as datas são a <strong style={{ color: COLORS.white }}>previsão de pagamento</strong> da Omie
          (o vencimento original aparece no título quando difere); previsto de agosto em diante e não pago é exigível
          e permanece no total até ser baixado; o anterior a agosto é legado nunca baixado, não saída futura — fica
          fora do total, visível abaixo. Os <strong style={{ color: COLORS.white }}>dias passados</strong> ficam no
          topo do cronograma: o que estava previsto no dia e o status real de cada título (✓ pago / em aberto). A
          Omie não informa a data exata da baixa — &quot;pago&quot; é o status atual do título.
        </p>
      </div>

      {/* Por grupo (linha do DRE / natureza) */}
      {grupos.length > 0 && (
        <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
          <div className="mb-2 flex items-center justify-between">
            <h3 className="text-sm font-bold text-white">Por natureza (90 dias + vencido recente)</h3>
            <span className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              90 dias · <span style={{ color: AMBER }}>vencido recente</span>
            </span>
          </div>
          <ul className="space-y-1.5">
            {grupos.map((g) => (
              <li key={g.grupo} className="flex items-center gap-2 text-xs">
                <span className="w-[200px] shrink-0 truncate" style={{ color: COLORS.muted }} title={g.grupo}>
                  {g.grupo}
                </span>
                <span className="min-w-0 flex-1">
                  <div className="flex h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
                    <div style={{ width: maiorGrupo > 0 ? `${((g.valor90d / maiorGrupo) * 100).toFixed(2)}%` : 0, background: COLORS.red }} />
                    <div style={{ width: maiorGrupo > 0 ? `${((g.vencidoRecente / maiorGrupo) * 100).toFixed(2)}%` : 0, background: AMBER }} />
                  </div>
                </span>
                <span className="w-[100px] shrink-0 text-right font-semibold tabular-nums text-white">{brl(g.valor90d)}</span>
                <span className="w-[100px] shrink-0 text-right tabular-nums" style={{ color: g.vencidoRecente > 0 ? AMBER : COLORS.muted }}>
                  {g.vencidoRecente > 0 ? brl(g.vencidoRecente) : "—"}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Cronograma dia a dia */}
      <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}>
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
          <span style={{ color: COLORS.muted }}>
            Cronograma por previsão de pagamento — {dados.dias.length} {dados.dias.length === 1 ? "data" : "datas"} nos próximos 90 dias
            {historico.length > 0 && (
              <>
                {" "}· dias passados no topo (<span style={{ color: COLORS.green }}>✓ pago</span> ·{" "}
                <span style={{ color: AMBER }}>em aberto</span>)
              </>
            )}{" "}
            · clique no dia para ver os títulos
          </span>
          {dados.dias.length > 0 && (
            <button
              type="button"
              onClick={() => setCronogramaAberto((o) => !o)}
              className="rounded-lg border px-2 py-1 transition-colors"
              style={{ color: COLORS.cyan, borderColor: `${COLORS.cyan}44` }}
            >
              {cronogramaAberto ? "Ocultar cronograma" : "Ver cronograma"}
            </button>
          )}
        </div>
        {cronogramaAberto && dados.dias.length > 0 && (
          <ul className="mt-3 space-y-1.5 border-t pt-3" style={{ borderColor: COLORS.panelBorder }}>
            {historico.map((h) => {
              const total = h.pago + h.aberto;
              return (
                <li key={`h:${h.data}`} className="text-xs" style={{ opacity: 0.7 }}>
                  <button
                    type="button"
                    onClick={() => setDiaAberto((a) => (a === `h:${h.data}` ? null : `h:${h.data}`))}
                    className="flex w-full items-center gap-2 text-left"
                  >
                    <span className="w-[38px] shrink-0 tabular-nums" style={{ color: COLORS.muted }}>
                      {ddmm(h.data)}
                    </span>
                    <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${COLORS.muted}99` }}>
                      D−{Math.max(difDias(h.data, referencia), 0)}
                    </span>
                    <span className="min-w-0 flex-1">
                      <div className="flex h-2 w-full overflow-hidden rounded-full" style={{ background: COLORS.panelBorder }}>
                        <div style={{ width: maiorDia > 0 && h.pago > 0 ? `max(2px, ${((h.pago / maiorDia) * 100).toFixed(2)}%)` : 0, background: COLORS.green }} />
                        <div style={{ width: maiorDia > 0 && h.aberto > 0 ? `max(2px, ${((h.aberto / maiorDia) * 100).toFixed(2)}%)` : 0, background: AMBER }} />
                      </div>
                    </span>
                    <span className="w-[44px] shrink-0 text-right text-[10px] tabular-nums" style={{ color: COLORS.muted }}>
                      {h.titulos} tít.
                    </span>
                    <span
                      className="w-[100px] shrink-0 text-right font-semibold tabular-nums"
                      style={{ color: h.aberto > 0 ? AMBER : COLORS.green }}
                      title={h.aberto > 0 ? `pago ${brl(h.pago)} · em aberto ${brl(h.aberto)}` : "tudo baixado na Omie"}
                    >
                      {brl(total)}
                    </span>
                  </button>
                  {diaAberto === `h:${h.data}` && (
                    <TitulosHistorico itens={dados.historicoTitulos.filter((t) => t.prev === h.data)} />
                  )}
                </li>
              );
            })}
            {historico.length > 0 && (
              <li className="flex items-center gap-2 text-[10px] uppercase tracking-wider" style={{ color: `${COLORS.muted}99` }}>
                <span className="h-px flex-1" style={{ background: COLORS.panelBorder }} />
                <span>hoje — previsto daqui pra frente</span>
                <span className="h-px flex-1" style={{ background: COLORS.panelBorder }} />
              </li>
            )}
            {dados.vencidoRecente.valor > 0 && (
              <li className="text-xs">
                <button
                  type="button"
                  onClick={() => setDiaAberto((a) => (a === "vencido" ? null : "vencido"))}
                  className="flex w-full items-center gap-2 text-left"
                >
                  <span className="w-[38px] shrink-0 tabular-nums" style={{ color: AMBER }}>
                    venc.
                  </span>
                  <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${AMBER}99` }}>
                    D+0
                  </span>
                  <span className="min-w-0 flex-1">
                    <Barra frac={maiorDia > 0 ? dados.vencidoRecente.valor / maiorDia : 0} cor={AMBER} />
                  </span>
                  <span className="w-[44px] shrink-0 text-right text-[10px] tabular-nums" style={{ color: COLORS.muted }}>
                    {dados.vencidoRecente.titulos} tít.
                  </span>
                  <span className="w-[100px] shrink-0 text-right font-semibold tabular-nums" style={{ color: AMBER }}>
                    {brl(dados.vencidoRecente.valor)}
                  </span>
                </button>
                {diaAberto === "vencido" && <Titulos itens={dados.titulos.filter((t) => t.vencido)} mostrarData />}
              </li>
            )}
            {dados.dias.map((d) => (
              <li key={d.data} className="text-xs">
                <button
                  type="button"
                  onClick={() => setDiaAberto((a) => (a === d.data ? null : d.data))}
                  className="flex w-full items-center gap-2 text-left"
                >
                  <span className="w-[38px] shrink-0 tabular-nums" style={{ color: COLORS.muted }}>
                    {ddmm(d.data)}
                  </span>
                  <span className="w-[34px] shrink-0 text-[10px] tabular-nums" style={{ color: `${COLORS.muted}99` }}>
                    D+{Math.max(difDias(referencia, d.data), 0)}
                  </span>
                  <span className="min-w-0 flex-1">
                    <Barra frac={maiorDia > 0 ? d.valor / maiorDia : 0} />
                  </span>
                  <span className="w-[44px] shrink-0 text-right text-[10px] tabular-nums" style={{ color: COLORS.muted }}>
                    {d.titulos} tít.
                  </span>
                  <span className="w-[100px] shrink-0 text-right font-semibold tabular-nums text-white">{brl(d.valor)}</span>
                </button>
                {diaAberto === d.data && (
                  <Titulos itens={dados.titulos.filter((t) => !t.vencido && t.prev === d.data)} />
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Vencido antigo — auditável, não some em silêncio */}
      {dados.vencidoAntigo.titulos > 0 && (
        <div className="mt-3 rounded-xl border p-4" style={{ background: COLORS.bg, borderColor: COLORS.panelBorder, opacity: 0.85 }}>
          <div className="flex flex-wrap items-center justify-between gap-2 text-xs">
            <span style={{ color: COLORS.muted }}>
              <strong style={{ color: COLORS.white }}>{brl(dados.vencidoAntigo.valor)}</strong> em{" "}
              {dados.vencidoAntigo.titulos} títulos vencidos antes de ago/2026 (o mais antigo de{" "}
              {dados.vencidoAntigo.desde ? ddmm(dados.vencidoAntigo.desde) + "/" + dados.vencidoAntigo.desde.slice(0, 4) : "—"}) —{" "}
              <span style={{ color: AMBER }}>fora do total</span> por decisão (25/08/2026): legado nunca baixado na Omie
            </span>
            <button
              type="button"
              onClick={() => setAntigoAberto((o) => !o)}
              className="rounded-lg border px-2 py-1 transition-colors"
              style={{ color: COLORS.cyan, borderColor: `${COLORS.cyan}44` }}
            >
              {antigoAberto ? "Ocultar" : "Ver por fornecedor"}
            </button>
          </div>
          {antigoAberto && (
            <ul className="mt-3 space-y-1 border-t pt-3 text-xs" style={{ borderColor: COLORS.panelBorder }}>
              {dados.vencidoAntigo.fornecedores.map((f) => (
                <li key={f.fornecedor} className="flex items-center justify-between gap-2">
                  <span className="truncate" style={{ color: COLORS.muted }} title={f.fornecedor}>
                    {f.fornecedor}{" "}
                    <span style={{ color: `${COLORS.muted}99` }}>
                      · {f.titulos} tít. · desde {ddmm(f.desde)}/{f.desde.slice(0, 4)}
                    </span>
                  </span>
                  <span className="shrink-0 tabular-nums text-white">{brl(f.valor)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </Panel>
  );
}
