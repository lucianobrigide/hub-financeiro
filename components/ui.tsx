import type { ReactNode } from "react";

export const COLORS = {
  bg: "#0a0e1a",
  panel: "#111726",
  panelBorder: "#1c2438",
  cyan: "#00d4d4",
  green: "#00ff88",
  white: "#ffffff",
  muted: "#8892a4",
  red: "#ff4d6d",
};

export const brl = (v: number) =>
  v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

export const num = (v: number) => v.toLocaleString("pt-BR");

export const pct = (v: number) =>
  `${v.toLocaleString("pt-BR", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}%`;

export function Na({ small = false }: { small?: boolean }) {
  return (
    <span
      className={small ? "text-[10px]" : "text-xs"}
      style={{ color: COLORS.muted, fontStyle: "italic", fontWeight: 400 }}
    >
      — sem dados ainda
    </span>
  );
}

export function Panel({
  title,
  children,
  className = "",
}: {
  title?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section
      className={`rounded-xl border p-4 ${className}`}
      style={{ background: COLORS.panel, borderColor: COLORS.panelBorder }}
    >
      {title && (
        <h2
          className="mb-3 text-xs font-semibold uppercase tracking-wider"
          style={{ color: COLORS.muted }}
        >
          {title}
        </h2>
      )}
      {children}
    </section>
  );
}

export function StatCircle({
  accent,
  children,
}: {
  accent: string;
  children: ReactNode;
}) {
  return (
    <div
      className="flex aspect-square w-40 flex-col items-center justify-center rounded-full border-2 px-4 text-center"
      style={{
        borderColor: accent,
        boxShadow: `0 0 24px ${accent}22, inset 0 0 24px ${accent}11`,
      }}
    >
      {children}
    </div>
  );
}

export function SemiGauge({ value, max }: { value: number | null; max: number }) {
  const has = value != null;
  const frac = has ? Math.min(Math.max(value / max, 0), 1) : 0;
  const r = 90;
  const cx = 110;
  const arc = Math.PI * r;
  const offset = arc * (1 - frac);
  const path = `M 20 110 A ${r} ${r} 0 0 1 200 110`;

  return (
    <div className="flex flex-col items-center">
      <svg viewBox="0 0 220 130" className="w-full max-w-[260px]">
        <path d={path} fill="none" stroke={COLORS.panelBorder} strokeWidth={16} strokeLinecap="round" />
        {has && (
          <path
            d={path}
            fill="none"
            stroke={COLORS.green}
            strokeWidth={16}
            strokeLinecap="round"
            strokeDasharray={arc}
            strokeDashoffset={offset}
          />
        )}
        <text
          x={cx}
          y={96}
          textAnchor="middle"
          fontSize={has ? "20" : "12"}
          fontWeight="700"
          fill={has ? COLORS.white : COLORS.muted}
          fontStyle={has ? "normal" : "italic"}
        >
          {has ? brl(value) : "— sem dados ainda"}
        </text>
      </svg>
      <div
        className="mt-1 flex w-full max-w-[260px] justify-between text-xs"
        style={{ color: COLORS.muted }}
      >
        <span>R$ 0</span>
        <span>{`${(max / 1000).toLocaleString("pt-BR", { minimumFractionDigits: 2 })} Mil`}</span>
      </div>
    </div>
  );
}

export function MiniKpi({
  label,
  value,
  accent = COLORS.white,
}: {
  label: string;
  value: string | null;
  accent?: string;
}) {
  return (
    <div
      className="flex-1 rounded-lg border px-3 py-2 text-center"
      style={{ background: COLORS.bg, borderColor: COLORS.panelBorder }}
    >
      <div className="text-[10px] uppercase tracking-wider" style={{ color: COLORS.muted }}>
        {label}
      </div>
      <div className="text-lg font-bold" style={{ color: accent }}>
        {value == null ? <Na small /> : value}
      </div>
    </div>
  );
}
