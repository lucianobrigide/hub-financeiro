#!/usr/bin/env node
// Diff de dois snapshots de não-regressão do CMV (ver snapshot.mjs).
//
// Uso:  node scripts/cmv-regression/diff.mjs <label-a> <label-b> [--mes-corte YYYY-MM]
//
// Regra: toda captura de mês ANTERIOR ao mês-corte (default: mês corrente) tem que
// bater EXATAMENTE entre os dois snapshots — qualquer diferença é regressão (exit 1).
// Diferenças no mês-corte em diante são listadas como informativas (mês aberto).

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const [a, b] = process.argv.slice(2).filter((x) => !x.startsWith("--"));
if (!a || !b) { console.error("uso: diff.mjs <label-a> <label-b> [--mes-corte YYYY-MM]"); process.exit(2); }
const idx = process.argv.indexOf("--mes-corte");
const mesCorte = idx > -1 ? process.argv[idx + 1]
  : `${new Date().getFullYear()}-${String(new Date().getMonth() + 1).padStart(2, "0")}`;

const load = (l) => JSON.parse(readFileSync(join(HERE, "snapshots", l, "raw.json"), "utf8"));
const A = load(a), B = load(b);
const keys = [...new Set([...Object.keys(A), ...Object.keys(B)])].sort();

const regressoes = [], infoAbertas = [], iguais = [];
for (const k of keys) {
  const mes = k.split("|")[1];
  const igual = JSON.stringify(A[k]) === JSON.stringify(B[k]);
  if (igual) { iguais.push(k); continue; }
  (mes < mesCorte ? regressoes : infoAbertas).push(k);
}

console.log(`diff '${a}' × '${b}' — corte ${mesCorte}`);
console.log(`  iguais: ${iguais.length}/${keys.length}`);
if (infoAbertas.length) {
  console.log(`  diferenças no mês aberto (${mesCorte}+, esperadas se houve mudança de custo/ingestão):`);
  for (const k of infoAbertas) console.log(`    ~ ${k}`);
}
if (regressoes.length) {
  console.log(`  REGRESSÕES (meses fechados divergiram — NÃO SUBIR):`);
  for (const k of regressoes) console.log(`    ✗ ${k}`);
  process.exit(1);
}
console.log("  ✓ meses fechados batem exatamente");

// comparativo da margem por canal×mês (informativo)
try {
  const csv = (l) => readFileSync(join(HERE, "snapshots", l, "margem.csv"), "utf8").trim().split("\n").slice(1);
  const parse = (lines) => Object.fromEntries(lines.map((ln) => { const c = ln.split(";"); return [`${c[0]}|${c[1]}`, +c[7]]; }));
  const ma = parse(csv(a)), mb = parse(csv(b));
  const deltas = Object.keys({ ...ma, ...mb }).sort()
    .map((k) => ({ k, da: ma[k] ?? 0, db: mb[k] ?? 0 }))
    .filter((x) => Math.abs(x.da - x.db) >= 0.005);
  if (deltas.length) {
    console.log("  Δ margem de contribuição (canal|mes: antes -> depois):");
    for (const { k, da, db } of deltas) console.log(`    ${k}: ${da.toFixed(2)} -> ${db.toFixed(2)} (${(db - da).toFixed(2)})`);
  } else console.log("  margem por canal×mês: sem diferenças");
} catch { /* margem.csv ausente em snapshot antigo */ }
