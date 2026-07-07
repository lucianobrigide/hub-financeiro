export type Granularidade = "dia" | "semana" | "mes";

export interface FluxoItem {
  data: string;
  categoria: string;
  descricao: string;
  valor: number;
  tipo: "entrada" | "saida";
}

export interface FluxoPeriodo {
  inicio: string;
  fim: string;
  entradas: number;
  saidas: number;
  saldo: number;
  saldoAcumulado: number;
  itens: FluxoItem[];
}

export interface FluxoCaixaData {
  periodos: FluxoPeriodo[];
  granularidade: Granularidade;
  saldoInicial: number;
  totalEntradas: number;
  totalSaidas: number;
  saldoFinal: number;
}
