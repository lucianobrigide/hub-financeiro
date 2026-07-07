# Kit — Fluxo de Caixa Projetado

## O que e

Tarefa isolada: construir a pagina "Fluxo de Caixa Projetado" do Hub Financeiro.
Voce recebe um esqueleto funcional com dados mock. Seu trabalho e montar o layout
e os componentes visuais. A integracao com dados reais sera feita depois, por outra pessoa.

A definicao de negocio do Fluxo de Caixa NAO esta fechada. O esqueleto e generico
(entradas/saidas/saldo ao longo do tempo com filtro de periodo). Voce tem liberdade
para propor UX, graficos e visualizacoes, mas NAO chumbe uma definicao de negocio
especifica — mantenha flexivel e facil de reconfigurar.

## Como rodar

```bash
npm install
npm run dev
# Abra http://localhost:3000/fc-projetado
```

Roda em mock mode por padrao (sem variavel de ambiente). Nao precisa de banco,
tokens ou conexao externa.

## Arquivos do kit

```
app/(hub)/fc-projetado/
  page.tsx      <- pagina principal (esqueleto — seu ponto de partida)
  types.ts      <- contrato de dados (shape que a pagina consome)
  mock.ts       <- dados 100% ficticios, auto-suficiente
```

## O que voce PODE mexer

- `app/(hub)/fc-projetado/` — a pagina, componentes locais, o mock
- `components/` — criar novos componentes de UI se precisar (prefixe com `Fc` para clareza)
- O arquivo `mock.ts` (adicionar cenarios, categorias, etc.)

## O que voce NAO PODE mexer

- `lib/data/` (providers de dados reais)
- `supabase/` (Edge Functions, migrations)
- `app/actions.ts`
- Arquivos `.env*`
- Nenhuma conexao externa, token ou credencial
- Outras paginas do hub (marketplaces, dre, etc.)

## Design system

Importe de `@/components/ui`:

| Export     | O que faz                                       |
|------------|------------------------------------------------|
| `COLORS`   | Paleta: bg, panel, panelBorder, cyan, green, white, muted, red |
| `brl(n)`   | Formata numero como moeda BRL (R$ 1.234,56)    |
| `num(n)`   | Formata numero com separador de milhar          |
| `pct(n)`   | Formata percentual (12,34%)                     |
| `Panel`    | Container padrao com borda e titulo opcional     |
| `MiniKpi`  | Card de KPI compacto (label + valor)             |
| `Na`       | Indicador "sem dados ainda" (para campos null)   |

### Cores

| Token          | Hex       | Uso                    |
|---------------|-----------|------------------------|
| `COLORS.bg`    | `#0a0e1a` | Fundo da pagina        |
| `COLORS.panel` | `#111726` | Fundo de paineis       |
| `COLORS.panelBorder` | `#1c2438` | Bordas           |
| `COLORS.cyan`  | `#00d4d4` | Accent primario        |
| `COLORS.green` | `#00ff88` | Valores positivos      |
| `COLORS.red`   | `#ff4d6d` | Valores negativos      |
| `COLORS.white` | `#ffffff` | Texto principal        |
| `COLORS.muted` | `#8892a4` | Texto secundario       |

### Stack

- Next.js 16 + React 19 + TypeScript
- Tailwind CSS v4
- Recharts (ja instalado — `import { BarChart, ... } from "recharts"`)

## Contrato de dados

Veja `app/(hub)/fc-projetado/types.ts`. Resumo:

```
FluxoCaixaData
  periodos: FluxoPeriodo[]    <- buckets de tempo (dia/semana/mes)
  granularidade               <- "dia" | "semana" | "mes"
  saldoInicial                <- saldo no inicio do periodo
  totalEntradas / totalSaidas <- agregados
  saldoFinal                  <- saldo ao final

FluxoPeriodo
  inicio / fim                <- datas ISO "YYYY-MM-DD"
  entradas / saidas           <- totais do periodo
  saldo                       <- entradas - saidas
  saldoAcumulado              <- saldo corrente
  itens: FluxoItem[]          <- movimentacoes individuais

FluxoItem
  data / categoria / descricao / valor / tipo ("entrada" | "saida")
```

Quando integrarmos com dados reais, vamos fornecer um provider que devolve esse
mesmo shape. Se o shape nao atender, documente o que precisa mudar.

## Requisitos da pagina

- Layout: entradas, saidas e saldo acumulado ao longo do tempo
- Filtro de periodo: dia / semana / mes (configuravel) — ja implementado no esqueleto
- Dados vem 100% do mock.ts (import direto, sem provider)
- Visual compativel com o resto do Hub (use COLORS e Panel)
- Generico e flexivel — NAO chumbar definicao de negocio especifica
- Sugestoes de UX/graficos sao bem-vindas

## Como devolver

1. Faca commits na branch `kit/fluxo-caixa`
2. Documente decisoes de layout/UX num arquivo `NOTAS.md` curto (na raiz ou em fc-projetado/)
3. Liste qualquer mudanca que precisou fazer no contrato de dados (types.ts)
4. NAO faca merge no main

## Integracao (uso interno — instrucoes para o Luciano)

Quando o colaborador devolver:

1. Revisar os componentes e mover para `components/` se fizer sentido reutilizar
2. Criar o provider real (RPC no Supabase) que devolve `FluxoCaixaData`
3. Conectar a pagina ao DashboardProvider ou provider dedicado de fluxo de caixa
4. Ajustar o contrato de dados se o colaborador sugeriu mudancas no types.ts
5. Trocar o import do mock pelo provider real
6. Testar com DATA_SOURCE=supabase
7. Merge da branch no main
