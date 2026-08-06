"use client";

import type { CronsStatus, CronInfo } from "@/lib/data/types";
import { COLORS, Panel, Na } from "./ui";

// Cor do semáforo. Escolhidas pra ler bem no dark do Hub.
const SEM = {
  verde: { dot: COLORS.green, label: "OK" },
  amarelo: { dot: "#ffb84d", label: "Atenção" },
  vermelho: { dot: COLORS.red, label: "Falhando" },
} as const;

function semOf(s: string) {
  return SEM[s as keyof typeof SEM] ?? SEM.amarelo;
}

// Confiabilidade do log, em linguagem clara + o aviso honesto.
const CONFIAB: Record<string, { tag: string; cor: string; aviso?: string }> = {
  honesto: { tag: "log confiável", cor: COLORS.muted },
  parcial: { tag: "log parcial", cor: "#ffb84d", aviso: "o log registra sucesso, mas não distingue bem uma falha" },
  suspeito: { tag: "log não confiável", cor: COLORS.red, aviso: "o log pode dizer “ok” mesmo com falha — o status vem do agendador, não do log" },
};

const CATEGORIAS: { key: string; titulo: string; desc: string }[] = [
  { key: "diario", titulo: "Diários", desc: "Rodam toda madrugada — puxam as vendas do dia e atualizam a margem." },
  { key: "semanal", titulo: "Semanais", desc: "Rodam aos domingos — reconferência longa de 30 dias (cancelamentos e repasses que chegam tarde)." },
  { key: "token", titulo: "Conexões (token)", desc: "Mantêm as conexões com as plataformas vivas. Se pararem, os outros crons não conseguem puxar dados." },
];

/** Frase humana do último run. */
function ultimaExecFrase(c: CronInfo): string {
  if (!c.ultima_exec) return "sem execução recente registrada";
  const quando = c.ultima_exec;
  const h = c.horas_atras;
  const quanto =
    h == null ? "" : h < 1 ? " (há minutos)" : h < 48 ? ` (há ${Math.round(h)}h)` : ` (há ${Math.round(h / 24)} dias)`;
  if (c.pg_status === "failed" && c.recuperado_em)
    return `tentou rodar ${quando}${quanto} mas FALHOU — recuperado às ${c.recuperado_em}`;
  if (c.pg_status === "failed") return `tentou rodar ${quando}${quanto} mas FALHOU`;
  // via_log: o agendador já não guarda o histórico (retém poucos dias), então a data
  // vem do log de dados — mostra isso, pra não parecer confirmação do agendador.
  if (c.via_log) return `registrou dados ${quando}${quanto}`;
  if (c.pg_status === "succeeded") return `rodou ${quando}${quanto}, com sucesso`;
  return `última execução ${quando}${quanto}`;
}

function CronCard({ c }: { c: CronInfo }) {
  const sem = semOf(c.semaforo);
  const conf = CONFIAB[c.confiab_log] ?? CONFIAB.honesto;
  const falhou = c.semaforo === "vermelho";

  return (
    <div
      className="rounded-xl border p-4"
      style={{
        background: COLORS.bg,
        borderColor: falhou ? `${COLORS.red}55` : COLORS.panelBorder,
      }}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span
              className="inline-block h-2.5 w-2.5 shrink-0 rounded-full"
              style={{ background: sem.dot, boxShadow: `0 0 8px ${sem.dot}66` }}
              aria-hidden
            />
            <span className="text-sm font-semibold text-white">{c.plataforma}</span>
          </div>
          <div className="mt-0.5 text-[11px]" style={{ color: COLORS.muted }}>
            {c.horario}
          </div>
        </div>
        <span
          className="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold uppercase tracking-wide"
          style={{ background: `${sem.dot}1a`, color: sem.dot }}
        >
          {sem.label}
        </span>
      </div>

      <p className="mt-3 text-xs leading-relaxed" style={{ color: "#c3cad6" }}>
        {c.o_que_faz}
      </p>

      <div className="mt-3 border-t pt-2" style={{ borderColor: COLORS.panelBorder }}>
        <div className="text-[11px]" style={{ color: falhou ? COLORS.red : COLORS.muted }}>
          {ultimaExecFrase(c)}
          {c.duracao_seg != null && c.pg_status === "succeeded" ? ` · ${c.duracao_seg}s` : ""}
        </div>
        {/* Falha recente mesmo com run ok depois — o incidente não some do painel. */}
        {(c.falhas_24h ?? 0) > 0 && c.ultima_falha && (
          <div className="mt-1 text-[10px]" style={{ color: "#ffb84d" }}>
            {c.falhas_24h === 1 ? "1 falha" : `${c.falhas_24h} falhas`} nas últimas 24h —{" "}
            {c.ultima_falha}
          </div>
        )}
        <div className="mt-1 flex items-center gap-1.5">
          <span className="text-[10px]" style={{ color: conf.cor }}>
            {conf.tag}
          </span>
          {conf.aviso && (
            <span className="text-[10px] italic" style={{ color: COLORS.muted }}>
              — {conf.aviso}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

export function CronsBoard({ status }: { status: CronsStatus | null }) {
  if (!status || status.crons.length === 0) {
    return (
      <Panel title="Crons">
        <Na />
      </Panel>
    );
  }

  const atencao = status.crons.filter((c) => c.semaforo !== "verde");

  return (
    <div className="space-y-6">
      {/* Título */}
      <div>
        <h1 className="text-lg font-bold text-white">Automações (Crons)</h1>
        <p className="mt-1 text-xs" style={{ color: COLORS.muted }}>
          O que roda sozinho pra manter o painel atualizado — quando rodou, se deu certo, e o que
          cada um alimenta. Atualizado em {status.gerado_em}.
        </p>
      </div>

      {/* Resumo */}
      <Panel>
        <div className="flex flex-wrap items-center gap-x-8 gap-y-3">
          <div>
            <div className="text-2xl font-bold text-white">
              {status.verdes}
              <span className="text-base font-normal" style={{ color: COLORS.muted }}>
                {" "}
                de {status.total}
              </span>
            </div>
            <div className="text-[11px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
              automações saudáveis
            </div>
          </div>
          <div className="flex gap-4">
            <ResumoDot cor={COLORS.green} n={status.verdes} label="OK" />
            <ResumoDot cor="#ffb84d" n={status.amarelos} label="Atenção" />
            <ResumoDot cor={COLORS.red} n={status.vermelhos} label="Falhando" />
          </div>
        </div>

        {atencao.length > 0 && (
          <div
            className="mt-4 rounded-lg border px-3 py-2"
            style={{ borderColor: `${COLORS.red}33`, background: `${COLORS.red}0d` }}
          >
            <div className="text-[11px] font-semibold uppercase tracking-wide" style={{ color: "#ffb84d" }}>
              Precisam de atenção
            </div>
            <ul className="mt-1 space-y-0.5">
              {atencao.map((c) => (
                <li key={c.jobname} className="text-xs" style={{ color: "#c3cad6" }}>
                  <span
                    className="mr-1.5 inline-block h-2 w-2 rounded-full align-middle"
                    style={{ background: semOf(c.semaforo).dot }}
                    aria-hidden
                  />
                  <span className="font-medium text-white">{c.plataforma}</span> ·{" "}
                  {c.horario.replace("Todo dia às ", "").replace("Todo domingo às ", "dom ")} — {ultimaExecFrase(c)}
                </li>
              ))}
            </ul>
          </div>
        )}
      </Panel>

      {/* Grupos */}
      {CATEGORIAS.map((cat) => {
        const items = status.crons.filter((c) => c.categoria === cat.key);
        if (items.length === 0) return null;
        return (
          <div key={cat.key}>
            <div className="mb-2">
              <h2 className="text-sm font-semibold text-white">{cat.titulo}</h2>
              <p className="text-[11px]" style={{ color: COLORS.muted }}>
                {cat.desc}
              </p>
            </div>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {items.map((c) => (
                <CronCard key={c.jobname} c={c} />
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function ResumoDot({ cor, n, label }: { cor: string; n: number; label: string }) {
  return (
    <div className="flex items-center gap-1.5">
      <span className="inline-block h-2.5 w-2.5 rounded-full" style={{ background: cor }} aria-hidden />
      <span className="text-sm font-semibold text-white">{n}</span>
      <span className="text-[11px]" style={{ color: COLORS.muted }}>
        {label}
      </span>
    </div>
  );
}
