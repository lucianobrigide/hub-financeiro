#!/usr/bin/env node
// Snapshot de não-regressão do CMV: captura a saída bruta de TODAS as RPCs que leem
// ml_custo_produto, por mês (últimos 6 meses cheios + mês corrente), e deriva a
// margem de contribuição (custos diretos) por canal × mês.
//
// Uso:  node scripts/cmv-regression/snapshot.mjs --label baseline
// Saída: scripts/cmv-regression/snapshots/<label>/{raw.json, margem.csv}
//
// Compare dois snapshots com: node scripts/cmv-regression/diff.mjs <label-a> <label-b>

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");

// .env.local do repo (mesmas credenciais do provider supabase.ts)
function loadEnv() {
  const env = {};
  for (const line of readFileSync(join(REPO, ".env.local"), "utf8").split("\n")) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) env[m[1]] = m[2].trim();
  }
  return env;
}
const ENV = loadEnv();
const URL_BASE = ENV.SUPABASE_URL || "https://klwczmapuupensozxbsr.supabase.co";
const KEY = ENV.SUPABASE_SERVICE_ROLE_KEY;
if (!KEY) { console.error("SUPABASE_SERVICE_ROLE_KEY ausente no .env.local"); process.exit(2); }

async function rpc(fn, args) {
  const res = await fetch(`${URL_BASE}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args ?? {}),
  });
  if (!res.ok) throw new Error(`${fn} ${JSON.stringify(args)} -> HTTP ${res.status}: ${await res.text()}`);
  return res.json();
}

// JSON canônico (chaves ordenadas) para diff estável
function canon(v) {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === "object")
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
  return v;
}

function ultimosMeses(n) {
  const out = [];
  const d = new Date();
  for (let i = n; i >= 0; i--) {
    const x = new Date(d.getFullYear(), d.getMonth() - i, 1);
    out.push(`${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}`);
  }
  return out;
}

const label = process.argv.includes("--label")
  ? process.argv[process.argv.indexOf("--label") + 1]
  : new Date().toISOString().replace(/[:T]/g, "-").slice(0, 19);
const MESES = ultimosMeses(6); // 6 meses cheios + corrente
const CANAIS = ["ml", "sp", "tt", "az", "b2b"];
const RPCS_MES = ["ml_cmv", "ml_cmv_cobertura", "sp_cmv", "tt_cmv", "az_cmv", "b2b_cmv", "ml_dre_diario", "dre_diario_canais"];

const raw = {};
for (const mes of MESES) {
  for (const fn of RPCS_MES) raw[`${fn}|${mes}`] = canon(await rpc(fn, { p_month: mes }));
  for (const canal of CANAIS) raw[`dre_sku|${mes}|${canal}`] = canon(await rpc("dre_sku", { p_canal: canal, p_month: mes }));
  process.stderr.write(`  ${mes} ok\n`);
}

// Margem de contribuição (custos diretos) por canal × mês:
// ML vem de ml_dre_diario; demais canais de dre_diario_canais. mc = fat − cmv − comissão − frete − ads.
const margem = [["canal", "mes", "fat", "cmv", "comissao", "frete", "ads", "mc"]];
const r2 = (n) => Math.round(n * 100) / 100;
for (const mes of MESES) {
  const acc = {};
  const add = (canal, r) => {
    const a = (acc[canal] ??= { fat: 0, cmv: 0, comissao: 0, frete: 0, ads: 0 });
    a.fat += r.fat ?? 0; a.cmv += r.cmv ?? 0; a.comissao += r.comissao ?? 0;
    a.frete += r.frete ?? 0; a.ads += r.ads ?? 0;
  };
  for (const r of raw[`ml_dre_diario|${mes}`] ?? []) add("ml", r);
  for (const r of raw[`dre_diario_canais|${mes}`] ?? []) add(r.canal, r);
  for (const canal of Object.keys(acc).sort()) {
    const a = acc[canal];
    margem.push([canal, mes, r2(a.fat), r2(a.cmv), r2(a.comissao), r2(a.frete), r2(a.ads),
      r2(a.fat - a.cmv - a.comissao - a.frete - a.ads)]);
  }
}

const outDir = join(HERE, "snapshots", label);
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "raw.json"), JSON.stringify(raw, null, 1));
writeFileSync(join(outDir, "margem.csv"), margem.map((r) => r.join(";")).join("\n") + "\n");
console.log(`snapshot '${label}': ${Object.keys(raw).length} capturas (${MESES[0]}..${MESES.at(-1)}) em ${outDir}`);
