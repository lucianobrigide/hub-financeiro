import type { FluxoCaixaData, FluxoItem, FluxoPeriodo, Granularidade } from "./types";

const CATEGORIAS_ENTRADA = [
  "Marketplace ML",
  "Marketplace Shopee",
  "TikTok Shop",
  "Amazon",
  "Vendas Internas",
  "Reembolso fornecedor",
];

const CATEGORIAS_SAIDA = [
  "Fornecedor — estoque",
  "Frete — transportadora",
  "Imposto — DAS/IRPJ",
  "Imposto — ICMS",
  "Embalagens",
  "Marketing — ADS",
  "Folha de pagamento",
  "Aluguel — CD",
  "Software / SaaS",
  "Tarifas bancárias",
];

function seedRandom(seed: number) {
  let s = seed;
  return () => {
    s = (s * 16807 + 0) % 2147483647;
    return s / 2147483647;
  };
}

function gerarItens(dataBase: string, rand: () => number): FluxoItem[] {
  const itens: FluxoItem[] = [];
  const numEntradas = 2 + Math.floor(rand() * 4);
  for (let i = 0; i < numEntradas; i++) {
    const cat = CATEGORIAS_ENTRADA[Math.floor(rand() * CATEGORIAS_ENTRADA.length)];
    itens.push({
      data: dataBase,
      categoria: cat,
      descricao: `${cat} — repasse`,
      valor: Math.round((5000 + rand() * 180000) * 100) / 100,
      tipo: "entrada",
    });
  }
  const numSaidas = 1 + Math.floor(rand() * 5);
  for (let i = 0; i < numSaidas; i++) {
    const cat = CATEGORIAS_SAIDA[Math.floor(rand() * CATEGORIAS_SAIDA.length)];
    itens.push({
      data: dataBase,
      categoria: cat,
      descricao: `${cat}`,
      valor: Math.round((1000 + rand() * 60000) * 100) / 100,
      tipo: "saida",
    });
  }
  return itens;
}

function agruparPorDia(dias: number): FluxoPeriodo[] {
  const rand = seedRandom(42);
  const periodos: FluxoPeriodo[] = [];
  let acumulado = 250000;

  const hoje = new Date();
  for (let i = dias - 1; i >= 0; i--) {
    const d = new Date(hoje);
    d.setDate(d.getDate() - i);
    const iso = d.toISOString().slice(0, 10);
    const itens = gerarItens(iso, rand);
    const entradas = itens.filter((x) => x.tipo === "entrada").reduce((s, x) => s + x.valor, 0);
    const saidas = itens.filter((x) => x.tipo === "saida").reduce((s, x) => s + x.valor, 0);
    const saldo = Math.round((entradas - saidas) * 100) / 100;
    acumulado = Math.round((acumulado + saldo) * 100) / 100;
    periodos.push({ inicio: iso, fim: iso, entradas, saidas, saldo, saldoAcumulado: acumulado, itens });
  }
  return periodos;
}

function agruparPorSemana(semanas: number): FluxoPeriodo[] {
  const dias = agruparPorDia(semanas * 7);
  const periodos: FluxoPeriodo[] = [];
  for (let i = 0; i < dias.length; i += 7) {
    const grupo = dias.slice(i, i + 7);
    const entradas = grupo.reduce((s, p) => s + p.entradas, 0);
    const saidas = grupo.reduce((s, p) => s + p.saidas, 0);
    const saldo = Math.round((entradas - saidas) * 100) / 100;
    const ultimo = grupo[grupo.length - 1];
    periodos.push({
      inicio: grupo[0].inicio,
      fim: ultimo.fim,
      entradas: Math.round(entradas * 100) / 100,
      saidas: Math.round(saidas * 100) / 100,
      saldo,
      saldoAcumulado: ultimo.saldoAcumulado,
      itens: grupo.flatMap((p) => p.itens),
    });
  }
  return periodos;
}

function agruparPorMes(meses: number): FluxoPeriodo[] {
  const dias = agruparPorDia(meses * 30);
  const periodos: FluxoPeriodo[] = [];
  for (let i = 0; i < dias.length; i += 30) {
    const grupo = dias.slice(i, i + 30);
    const entradas = grupo.reduce((s, p) => s + p.entradas, 0);
    const saidas = grupo.reduce((s, p) => s + p.saidas, 0);
    const saldo = Math.round((entradas - saidas) * 100) / 100;
    const ultimo = grupo[grupo.length - 1];
    periodos.push({
      inicio: grupo[0].inicio,
      fim: ultimo.fim,
      entradas: Math.round(entradas * 100) / 100,
      saidas: Math.round(saidas * 100) / 100,
      saldo,
      saldoAcumulado: ultimo.saldoAcumulado,
      itens: grupo.flatMap((p) => p.itens),
    });
  }
  return periodos;
}

export function getFluxoCaixaMock(granularidade: Granularidade): FluxoCaixaData {
  let periodos: FluxoPeriodo[];
  switch (granularidade) {
    case "dia":
      periodos = agruparPorDia(30);
      break;
    case "semana":
      periodos = agruparPorSemana(8);
      break;
    case "mes":
      periodos = agruparPorMes(6);
      break;
  }

  const totalEntradas = Math.round(periodos.reduce((s, p) => s + p.entradas, 0) * 100) / 100;
  const totalSaidas = Math.round(periodos.reduce((s, p) => s + p.saidas, 0) * 100) / 100;
  const saldoInicial = 250000;
  const saldoFinal = periodos.length > 0 ? periodos[periodos.length - 1].saldoAcumulado : saldoInicial;

  return { periodos, granularidade, saldoInicial, totalEntradas, totalSaidas, saldoFinal };
}
