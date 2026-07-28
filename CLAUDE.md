@AGENTS.md

# Hub Financeiro — CLAUDE.md (fonte de verdade)

> **Autoridade:** este arquivo é a fonte de verdade do projeto; o Notion é espelho.
> Só fato verificado no código/runtime. Fato volátil leva **data de verificação**.
> Última revisão geral: **28/07/2026**.

## Visão geral

E-commerce de **panelas/cookware** (verificado: descrições de itens e custos em `PRODUTOS.xlsx`/`ml_custo_produto`), **multicanal**. O Hub responde, por **canal** e por **mês**: *quanto entrou de fato (líquido)* e *qual a margem de contribuição real* (faturamento → deduções → M.C.), e monta o **DRE consolidado** (receita → M.C. → despesas operacionais → resultado).

- Canais (verificado em `lib/data/supabase.ts` `CANAIS`): **Mercado Livre, Shopee, TikTok Shop, Amazon, B2B** (id interno `vendas-internas`, nome de exibição "B2B").
- Despesas operacionais (abaixo da M.C.) vêm da **Omie** (contas a pagar + conta corrente).
- Regime tributário: **Lucro Real** (conforme `APRENDIZADOS_SHOPEE_ML.md`; consistente com PIS/COFINS + DIFAL no DRE — ver Integrações/Omie).

## Stack

- **Front:** Next.js **16.2.9**, React **19.2.4**, Tailwind **4**, Recharts (verificado em `package.json`). App Router, `app/` na raiz (sem `src/`).
- **Backend:** **Supabase Postgres** — **toda a lógica pesada vive no banco**: RPCs PL/pgSQL, extensão `extensions.http` (HTTP a partir do Postgres), `pg_cron` (agendador), **Vault** (`vault.decrypted_secrets`) para segredos. **113 migrations** em `supabase/migrations/` (verificado).
- **Edge Functions (Deno):** gateway fino de token e ingestão pesada (ex.: `ml-token` para refresh do ML). Não versionadas neste repo.
- Rodar local: `npm run dev` (porta 3000). `DATA_SOURCE=supabase` liga o provider real (ver Arquitetura de dados). Config em `.claude/launch.json`.

## Arquitetura de dados

### Camada `lib/data/`
- `index.ts` — seleciona o provider: `DATA_SOURCE === "supabase"` → `supabaseProvider`; **senão `mockProvider` (default)**. O `launch.json` já injeta `DATA_SOURCE=supabase`.
- `types.ts` — interface `DataProvider` e todos os tipos que a UI consome. Método obrigatório `getDashboard(month?)`; opcionais `getCronsStatus`, `getDreGrupoR`, `getDreGrupoRDetalhe`, `getDreItens`, `getDreTopo`, `getDreSku`.
- `supabase.ts` (~889 linhas) — provider real. Chama **RPCs** do Postgres via PostgREST com `SUPABASE_SERVICE_ROLE_KEY` (server-side). URL default hardcoded: `https://klwczmapuupensozxbsr.supabase.co` (não é segredo; overridável por `SUPABASE_URL`).
- `mock.ts` — dados fixos para desenvolvimento sem banco.

### RPCs (a lógica)
`getDashboard(mes)` monta o dashboard chamando um RPC por bloco/canal. Verificado em `supabase.ts`:
- **ML:** `ml_dashboard`, `ml_faturamento_ml`, `ml_comissao`, `ml_ads`, `ml_friccao`, `ml_frete`, `ml_full`, `ml_cmv`, `ml_dre_diario`; afiliados/DIFAL via `sp_afiliados_ml`/`sp_difal_ml`.
- **Shopee:** `sp_faturamento`, `sp_cmv`, `sp_afiliados`, `shopee_ads`, `shopee_difal`, `sp_custo_devolucoes`, `sp_repasse`.
- **TikTok:** `tt_faturamento`, `tt_deducoes`, `tt_cmv`.
- **Amazon:** `az_faturamento`, `az_deducoes`, `az_comissao`, `az_frete_mes`, `az_cmv`.
- **B2B:** `b2b_faturamento`, `b2b_cmv`.
- **Série diária (gráfico):** `ml_dre_diario` (ML) + `dre_diario_canais` (demais canais).
- **DRE:** topo (Receita → M.C.) = `getDreTopo` (reusa `getDashboard`, consolida acima da M.C.); **Grupo R** (despesas) = `omie_dre_grupo_r` / `_detalhe` / `omie_dre_itens` (drill-down 3 níveis). Fonte do Grupo R: view `omie_dre_lancamentos`.
- **Saúde dos crons:** `crons_status`.

### pg_cron
**22 jobs ativos (verificado 28/07/2026).** Horários no cron são **UTC** (BRT = −3h). Ingestão por canal + keepalive de token + reconferências:
```
ml-diario (0 6)         ml-semanal (0 8 dom)     ml-refresh-token (*/30)
ml-ads-item (25 6)      ml-ads-reconferir (0 9)  ml_fatura_tarifas (30 4)
ml_full_ccolpa (40 4)
shopee-diario (30 6)    shopee-semanal (15 8 dom) shopee-token-keepalive (15 */3)
shopee-escrow-meiodia (0 15)  shopee-escrow-tarde (0 21)
shopee-ads-reconferir-meiodia (0 15)  shopee-ads-reconferir-tarde (0 21)
tt-diario (0 7)         tt-semanal (45 8 dom)    tt-token-keepalive (0 7)
az-diario (15 6)        az-semanal (30 8 dom)
omie-diario (0 8)       omie-semanal (30 8 dom)
tiny-token-keepalive (25 */4)
```
Monitorar: aba **`/crons`** (RPC `crons_status`) e tabela `oauth_refresh_log` (mensagens dos crons: `shopee_cron`, `tt_cron`, `omie_diario`, etc.).

## Módulos (ativos vs stub)

**Ativos (verificado em `app/(hub)/`):**
- `/` — dashboard: cards por canal (faturamento → deduções → M.C.) + gráfico faturamento/M.C. por dia. (`HubMain.tsx`)
- `/dre` — DRE consolidado do mês fechado, com drill-down em 3 níveis (linha → categoria → item).
- `/crons` — painel de saúde dos crons.
- `/marketplaces/{mercado-livre,shopee,tiktok,amazon,vendas-internas}` — páginas de canal (delegam ao componente `CanalDashboard`).
- `/login` + gate de acesso (ver Convenções / Deploy).

**Stubs (placeholder vazio — verificado: usam `<Placeholder/>`):**
- `/fc-projetado` — **Fluxo de Caixa Projetado: NÃO construído.**
- `/previsao-impostos` — **Previsão de Impostos: NÃO construído.**

## Integrações por canal

Padrão comum: OAuth com `refresh_token` **só no Vault**; `*_oauth_state` (linha `id=1`) guarda `access_token`+`expires_at`; HTTP feito de dentro do Postgres; jobs longos usam `SET statement_timeout`. Detalhe histórico (ML/Shopee) em `APRENDIZADOS_SHOPEE_ML.md`.

- **Mercado Livre** — cron `ml-diario`; ADS via `ml-ads-item`/`ml-ads-reconferir` (captura de D-1 às 03:00 vem parcial → reconferência re-puxa); tarifas de fatura extras em `ml_fatura_tarifas` (assessoria CPAC/Minha página CESM → DRE R6) e `ml_full_ccolpa` (coleta pré-agendada → Full/C7). Régua: comissão = `sale_fee` (CVVML). Token: `ml-refresh-token` + Edge Function `ml-token`.
- **Shopee** — cron `shopee-diario` (`shopee_cron_diario`: lista pedidos → detalhe → **escrow** (repasse, fonte de verdade das deduções) → ADS → DIFAL). Escrow re-passa 12h/18h (`shopee-escrow-*`) contra o lag do último dia. ADS reconferido 12h/18h (`shopee-ads-reconferir-*`) — a captura das 03:30 pode falhar/vir parcial.
- **TikTok Shop** — cron `tt-diario` (`tt_cron_diario`: order search → `tt_fill_finance` by-order). **Régua (alterada 24/07/2026):** `tt_faturamento`/`tt_cmv` contam **pedido pago antes de liquidar** (exclui UNPAID/CANCELLED); receita = `fin_revenue` quando liquidado, senão `payment_total` (estimativa); deduções só de liquidado (nota "X de Y liquidados"). `tt-semanal` re-sincroniza 30 dias (revisão de cancelados).
- **Amazon** — crons `az-diario`/`az-semanal`.
- **B2B (Tiny)** — notas fiscais do Tiny (`b2b_notas`/`b2b_itens`). Discriminador do canal B2B (o `/notas` do Tiny devolve TODAS as NFs, marketplace incluso): **`ecommerce` vazio + `tipo` "S" + `naturezaOperacao` "Venda%"** (exclui devolução de compra e remessa/bonificação). Ingestão: `b2b_fill_notas(de, ate, off_start, max_pages)` — em lotes. **NÃO tem cron: ingestão manual** (só `tiny-token-keepalive` existe). (Verificado 28/07/2026.)
- **Omie (despesas → DRE Grupo R)** — cron `omie-diario` (`omie_fill_despesas`: re-sync completo das contas a pagar) + `omie-semanal` (conta corrente `omie_fill_movimentos` + fornecedores). Classificação do DRE: linha vem do **PROJETO** (`omie_projeto_dre`), fallback **categoria** (`omie_dre_mapa`); include/exclude por categoria. **PIS/COFINS** (2.06.03→I3, 2.06.04→I4) e **DIFAL** (2.06.94→I1) entram acima da M.C.; competência dos impostos = mês do vencimento −1. Detalhe no Notion.

## Deploy

- Vercel, projeto `hub-financeiro`, auto-deploy do `main` via integração GitHub. Não há `vercel.json` nem `.vercel/` no repo (verificado).
- URL: `hub-financeiro-omega.vercel.app`
- **Verificado em 28/07/2026: conta Vercel PAUSADA.** Produção indisponível, builds não disparam. Motivo não apurado.
- Último deploy de produção: `2a063bd` (16/07/2026). Ao despausar, o próximo build salta para o HEAD atual — os commits acumulados de uma vez.
- **DEPENDÊNCIA:** `ML_REDIRECT_URI` aponta para `{URL}/api/auth/callback`. Enquanto pausado, **não é possível reautorizar o Mercado Livre**. O refresh diário **NÃO** é afetado (roda na Edge Function `ml-token`, no Supabase).
- **GATILHO:** antes de reautorizar o ML, **despausar a Vercel**. Sem isso o callback não responde.
- **Uso operacional:** **apenas local** — app no Dock apontando para `localhost:3000`; ninguém acessa a URL de produção. O deploy existe hoje só como callback do OAuth ML. (Confirmado 28/07/2026.)

> **Regra:** ao despausar a Vercel, atualizar esta seção com a data.

## Convenções

- **CLAUDE.md é a fonte de verdade; Notion é espelho.** Ao mudar regra/arquitetura, atualizar aqui primeiro.
- **Toda sessão termina com commit + push** e confirmação por escrito (nº de commits, SHA do HEAD remoto, working tree limpo/sincronizado).
- **Conflito de informação:** reportar o conflito ao Luciano; **não escolher sozinho** qual está certa.
- **`proxy.ts` na raiz é o correto no Next 16 — substitui o `middleware.ts`. A ausência de `middleware.ts` é ESPERADA, não é bug.** Exporta `proxy(req)` + `config` (matcher). Faz o gate de acesso: em produção exige o cookie `hub_auth`; em `localhost` libera sem gate.
- **`AGENTS.md`** (importado no topo deste arquivo) = regras do **Next 16** para agentes (ler `node_modules/next/dist/docs/` antes de escrever código Next). **`README.md`** é boilerplate do create-next-app (ignorar).
- **`APRENDIZADOS_SHOPEE_ML.md`** = guia histórico de ingestão **só de ML e Shopee**. Útil para as "pegadinhas" de auth/escrow/billing, mas **incompleto/defasado** — ver divergências abaixo. Não copiar cego.

### Divergências APRENDIZADOS × código (reconciliado 28/07/2026)
- Cobre **só ML e Shopee**. **Não** contém TikTok, Amazon, B2B/Tiny nem Omie/DRE de despesas (todo o motor de despesas, impostos e DRE consolidado).
- Descreve TikTok como inexistente; a régua atual do TikTok ("pago antes de liquidar", 24/07/2026) é posterior.
- Não reflete o DRE por Omie (Grupo R, PIS/COFINS I3/I4, DIFAL, tarifas de fatura ML, CCOLPA).

## Segredos & hardcodes

- Segredos reais: **Vault** (Supabase) + `.env.local` (gitignored: `SUPABASE_SERVICE_ROLE_KEY`, `ML_CLIENT_SECRET`, `SITE_ACCESS_CODE`, `SUPABASE_URL`).
- **Hardcoded no código** (não-segredo, mas fixo): código de acesso do site **`"1914"`** (fallback de `SITE_ACCESS_CODE` em `proxy.ts` e `app/api/login/route.ts`), `SUPABASE_URL`, `ML_CLIENT_ID`, `ML_REDIRECT_URI`.

## Pendências conhecidas (28/07/2026)

- **43 commits** foram pushados para `origin/main` em 28/07/2026 (HEAD remoto `a0e887d`) — repo sincronizado.
- Módulos stub: **Fluxo de Caixa Projetado** e **Previsão de Impostos** (em desenho).
- **Cron de ingestão do B2B/Tiny** (hoje manual via `b2b_fill_notas`).
- **DAS/IR** (impostos sobre receita além de PIS/COFINS) — ainda não capturados.
- **Vercel PAUSADA** (ver Deploy) — reautorização do ML bloqueada até despausar.
