@AGENTS.md

# Hub Financeiro — CLAUDE.md (fonte de verdade)

> **Autoridade:** este arquivo é a fonte de verdade do projeto; o Notion é espelho.
> Só fato verificado no código/runtime. Fato volátil leva **data de verificação**.
> Última revisão geral: **28/07/2026**.

## Visão geral

E-commerce de **panelas/cookware** (verificado: descrições de itens e custos em `PRODUTOS.xlsx`/`ml_custo_produto`), **multicanal**. O Hub responde, por **canal** e por **mês**: *quanto entrou de fato (líquido)* e *qual a margem de contribuição real* (faturamento → deduções → M.C.), e monta o **DRE consolidado** (receita → M.C. → despesas operacionais → resultado).

- Canais (verificado em `lib/data/supabase.ts` `CANAIS`): **Mercado Livre, Shopee, TikTok Shop, Amazon, SHEIN (MVP 07/08/2026 — credencial integrada, ingestão pendente), B2B** (id interno `vendas-internas`, nome de exibição "B2B").
- Despesas operacionais (abaixo da M.C.) vêm da **Omie** (contas a pagar + conta corrente).
- Regime tributário: **Lucro Real** (conforme `APRENDIZADOS_SHOPEE_ML.md`; consistente com PIS/COFINS + DIFAL no DRE — ver Integrações/Omie).
- **Argumento central do projeto:** os fechamentos manuais da equipe são **otimistas em 3 de 3 canais** (sempre na mesma direção). O Hub existe para medir o número real. Ver `LICOES.md`.

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

### CMV com vigência temporal (03/08/2026)
- `ml_custo_produto` tem **vigência por linha**: `[vigencia_inicio, vigencia_fim)`, `fim NULL` = vigente; PK `(sku, vigencia_inicio)` + constraint EXCLUDE (btree_gist) impede vigências sobrepostas do mesmo SKU. Linhas originais: `vigencia_inicio = 2000-01-01`.
- **Alteração de custo NUNCA é UPDATE no valor** — trigger bloqueia. Fluxo: `cmv_alterar_custo(sku, novo_custo, data_vigencia)` fecha a linha vigente e insere a nova (função revogada de anon/authenticated; rodar como service_role).
- As 9 RPCs que leem CMV (`ml_cmv`, `ml_cmv_cobertura`, `sp_cmv`, `tt_cmv`, `az_cmv`, `b2b_cmv`, `ml_dre_diario`, `dre_diario_canais`, `dre_sku`) fazem **range join ancorado na data de competência** de cada canal (ML `ml_pedidos.data`; Shopee/TT `create_time`@SP; AZ `purchase_date`; B2B `data_emissao`) — custo novo só afeta vendas de `vigencia_inicio` em diante; meses fechados não mudam.
- **Não-regressão:** `scripts/cmv-regression/` — `snapshot.mjs` captura as 9 RPCs × últimos 6 meses + margem por canal×mês; `diff.mjs` compara dois snapshots (meses fechados têm que bater exato). Rollback completo em `scripts/cmv-regression/rollback_cmv_vigencia.sql`. Migrations `20260803190001/190002`.

### pg_cron
**24 jobs ativos (verificado 03/08/2026).** Horários no cron são **UTC** (BRT = −3h). Ingestão por canal + keepalive de token + reconferências:
```
ml-diario (0 6)         ml-semanal (0 8 dom)     ml-refresh-token (*/30)
ml-ads-item (25 6)      ml-ads-reconferir (0 9)  ml_fatura_tarifas (30 4)
ml_full_ccolpa (40 4)
shopee-diario (30 6)    shopee-semanal (15 8 dom) shopee-token-keepalive (15 */3)
shopee-escrow-meiodia (0 15)  shopee-escrow-tarde (0 21)
shopee-ads-reconferir-meiodia (0 15)  shopee-ads-reconferir-tarde (0 21)
tt-diario (0 7)         tt-semanal (45 8 dom)    tt-token-keepalive (0 7)
az-diario (15 6)        az-semanal (30 8 dom)
azads-diario (45 6)     azads-colher (25 7)
omie-diario (0 8)       omie-semanal (30 8 dom)
tiny-token-keepalive (25 */4)
```
Monitorar: aba **`/crons`** (RPC `crons_status`) e tabela `oauth_refresh_log` (mensagens dos crons: `shopee_cron`, `tt_cron`, `omie_diario`, etc.).

## Onde as réguas vivem (mapa)

> **O que este arquivo é:** o CLAUDE.md é **inventário + decisões**, **não** um tratado de réguas. As **réguas fundas** (competência, status, escrow, deduções, pegadinhas de API) **não estão aqui** — vivem no código e no `APRENDIZADOS_SHOPEE_ML.md`. Este mapa só diz **onde cada uma vive**. Vai mexer numa régua? Siga o ponteiro e leia a fonte — não confie neste resumo. (Ponteiros verificados em 28/07/2026.)

- **Réguas ML** (venda `paid + partially_refunded`; competência `date_closed`@SP; custos de billing por `creation_date`/mês-calendário; ciclo 23→22): `APRENDIZADOS_SHOPEE_ML.md` §A3.1, §A3.2, §A3.5 + RPCs `ml_faturamento_ml`, `ml_comissao`, `ml_ads`, `ml_dre_diario`; cron `ml_cron_diario`. Deduções da M.C.: §A3.4.
- **`sale_fee` e o que NÃO entra** (CFONPN, CVVPRC/CVVFNU, estornos, CXDE): bloco "Billing ML — o que NÃO entra" acima. **BPAD credita o ADS** (ADS líquido): RPC `ml_ads` (comentário em `lib/data/supabase.ts`) + §A3.4.
- **Réguas Shopee** (bruta = não-cancelados; escrow = repasse desde a venda; ADS/DIFAL fora do escrow, na wallet): `APRENDIZADOS_SHOPEE_ML.md` §B3.2, §B3.4 + RPCs `sp_faturamento`, `sp_repasse`; cron `shopee_cron_diario` (fases lista→escrow→ADS→DIFAL); vazão do escrow em `shopee_fill_escrow`.
- **TikTok** (guard "não-liquidado" = `total_count=0` + array vazio; taxonomia de retry): função `tt_fill_finance`; cron `tt_cron_diario`; régua de faturamento (pago antes de liquidar) em `tt_faturamento` (ver §Integrações/TikTok).
- **Omie / DRE de despesas** (Grupo R; classificação projeto→categoria; PIS/COFINS/DIFAL): view `omie_dre_lancamentos` + RPC `omie_dre_grupo_r`; ingestão `omie_fill_despesas`. (Fora do escopo do APRENDIZADOS.)
- **B2B / Tiny** (discriminador `ecommerce` vazio + natureza `Venda%`): função `b2b_fill_notas`; leitura `b2b_faturamento` (ver §Integrações/B2B).
- **Pegadinhas de API** (ML billing trunca em silêncio, `detail_sub_types` plural, `document_type` obrigatório, `from_id`+ASC, `CURLOPT_TIMEOUT_MS`; Shopee dedup da wallet, caps de janela): `APRENDIZADOS_SHOPEE_ML.md` §A2.5, §A2.6 e §B2, §B2.1.
- **Pegadinhas NOVAS do billing ML (03/08/2026):** (a) o endpoint `/billing/integration/.../details` passou a rate-limitar agressivo (~31/07): HTTP 429 `local_rate_limited` já na 2ª chamada em rajada — todo caller precisa de backoff (nunca retry imediato); (b) **zero silencioso**: sob throttle a API pode responder **200 com `total=0` e `results` vazio** — a mesma query, minutos depois, devolve o total real. `total=0` com linhas já no banco = suspeito, re-ler antes de aceitar. Ambos tratados em `ml_fill_billing`/`ml_api_total` (migration `20260803120001_ml_billing_backoff_429`).
- **Fundações comuns** (HTTP de dentro do Postgres, custódia OAuth no Vault, advisory locks): `APRENDIZADOS_SHOPEE_ML.md` §0.3, §0.4, §0.5.

## Mudanças de 05/08/2026 (sessão de conferência do DRE — Luciano)

- **Crons diários resilientes:** cada fase/passo roda em subtransação com log de falha próprio — um timeout não descarta mais o dia inteiro (incidente shopee-diario 05/08, SSL timeout + rollback). Shopee `20260805140001`; ML/TT/AZ `150001`. `crons_status` ganhou `falhas_24h`/`ultima_falha`/`recuperado_em` e lê falhas de fase dos logs de app (`140002`/`150002`); UI em `CronsBoard.tsx`.
- **Omie AP — competência padrão = `data_entrada`** (a competência que o financeiro mantém na Omie), fallback emissão/vencimento — `200002`. Regras específicas prevalecem: PIS/COFINS (venc−1, inalterada); **Frete Flex** (projeto `11028072487` → C2, forca_inclusao; quinzena: doc "2ª%" = emissão−1 mês, "1ª" = mês da NF — régua do Luciano domina sobre a entrada) `190001`/`200001`; **parcelamento DIFAL BA** (fornecedor `10705160510`: sem categoria → assume 2.06.94/I1; competência = vencimento; entrada jun R$16k, nada em jul, 59×R$15.652,51 de 20/08/2026 a jun/2031) `160002`/`190002`; CABFORT parcelas (inalterada).
- **Órfãos Omie (soft-delete):** título que some da ListarContasPagar é carimbado em `ausente_desde` e sai do DRE (nunca deletado; volta se reaparecer) — `160001`. Causa raiz: baixas/renegociações re-lançam títulos com id novo.
- **`forca_inclusao` por projeto** (lançamento entra no DRE mesmo com categoria excluída): ligado SÓ em "Fretes Flex". Foi testado em "Marketing & Tráfego" e **REVERTIDO em ~30min** (dupla contagem ~R$294k: boletos de ads de plataforma usam esse projeto) — `180001` + revert `180002`. ⚠️ Nunca ligar sem auditar TODOS os lançamentos do projeto antes.
- **Mapa:** +7 categorias (Multas, Aluguel Equip., Refeições, Postais, Mat. Consumo, Seguros→R5, Viagens→R19) `170001`/`190001`. **GDB = folha terceirizada (mão de obra), RECONFIRMADA em R3** pelo Luciano (obs em 2.10.93; não mudar de linha sem nova decisão).
- **DRE UI:** coluna AV% calculada (% da Receita Bruta) em todos os níveis do drill-down (`DreTable.tsx`).
- **PENDENTE — regime de adiantamentos (aguardando Fernanda):** adiantamento 2.08.01 com projeto de linha = despesa no mês do pagamento; NF de baixa com projeto **"Baixa de Adiantamento"** = neutra no DRE. Procedimento: `../PROCEDIMENTO_FERNANDA_ADIANTAMENTOS.md`. ⚠️ **NÃO ligar as regras antes** de a Fernanda criar o projeto e marcar o backlog jan/2026→hoje (senão o histórico dobra). Diferenças por retenção (ISS etc.) são esperadas; DRE contará o líquido pago.

## Módulos (ativos vs stub)

**Ativos (verificado em `app/(hub)/`):**
- `/` — dashboard: cards por canal (faturamento → deduções → M.C.) + gráfico faturamento/M.C. por dia. (`HubMain.tsx`)
- `/dre` — DRE consolidado do mês fechado, com drill-down em 3 níveis (linha → categoria → item).
- `/crons` — painel de saúde dos crons.
- `/marketplaces/{mercado-livre,shopee,tiktok,amazon,shein,vendas-internas}` — páginas de canal (delegam ao componente `CanalDashboard`).
- `/login` + gate de acesso (ver Convenções / Deploy).

**Stubs (placeholder vazio — verificado: usam `<Placeholder/>`):**
- `/fc-projetado` — **Fluxo de Caixa Projetado: NÃO construído.**
- `/previsao-impostos` — **Previsão de Impostos: NÃO construído.**

## Integrações por canal

Padrão comum: OAuth com `refresh_token` **só no Vault**; `*_oauth_state` (linha `id=1`) guarda `access_token`+`expires_at`; HTTP feito de dentro do Postgres; jobs longos usam `SET statement_timeout`. Detalhe histórico (ML/Shopee) em `APRENDIZADOS_SHOPEE_ML.md`.

- **Mercado Livre** — cron `ml-diario`; ADS via `ml-ads-item`/`ml-ads-reconferir` (captura de D-1 às 03:00 vem parcial → reconferência re-puxa); tarifas de fatura extras em `ml_fatura_tarifas` (assessoria CPAC/Minha página CESM → DRE R6) e `ml_full_ccolpa` (coleta pré-agendada → Full/C7). Régua: comissão = `sale_fee` do pedido, que **é composto por `CVVML + CVVPRC + CVVFNU`** (provado pedido a pedido — não é só CVVML). O que **NÃO** entra no cálculo do billing ML: ver bloco "Billing ML — o que NÃO entra" abaixo. Token: `ml-refresh-token` + Edge Function `ml-token`.
- **Shopee** — cron `shopee-diario` (`shopee_cron_diario`: lista pedidos → detalhe → **escrow** (repasse, fonte de verdade das deduções) → ADS → DIFAL). Escrow re-passa 12h/18h (`shopee-escrow-*`) contra o lag do último dia. ADS reconferido 12h/18h (`shopee-ads-reconferir-*`) — a captura das 03:30 pode falhar/vir parcial.
- **TikTok Shop** — cron `tt-diario` (`tt_cron_diario`: order search → `tt_fill_finance` by-order). **Régua:** `tt_faturamento`/`tt_cmv` contam **pedido pago antes de liquidar** (exclui UNPAID/CANCELLED); receita bruta = `fin_revenue` quando liquidado, senão `payment_total`. **Deduções são SETTLED-ONLY, nunca estimadas** — o order detail `GET /order/202309/orders` **não traz `fee_breakdown` antes de liquidar** (só `payment`/preço; provado ao vivo 28/07/2026), e o `/finance` devolve zeros até liquidar → o dado de dedução **não existe** antes do settlement (`20260728120001`, 28/07). Exibição regida pelo **piso de cobertura** (ver Convenções): abaixo do piso o card fica "em consolidação" (bruta/CMV/margem bruta reais, M.C. suprimida); acima, M.C. sobre o subconjunto liquidado dos dois lados. `tt-semanal` re-sincroniza 30 dias (revisão de cancelados).
- **Amazon** — crons `az-diario`/`az-semanal`.
- **Amazon Ads (integrado 03/08/2026)** — app LwA separada da SP-API, prefixo **`azads_`**. Custódia no Vault (`azads_*`); troca do code **dentro do Postgres** (`azads_exchange_code` + allowlist de redirect); callback principal = Edge **`amazon-ads-callback`** (a rota Vercel `callback-amazon-ads` é alternativa; Vercel segue pausada por cota); gateway de token = Edge **`amazon-ads-token`**. Perfil único BR (`1926422998361173`, BRL, America/Sao_Paulo). **Ingestão:** Reports v3 são assíncronos (~12–15 min de fila) → fila `azads_report_jobs` em 3 estados honestos (`PENDENTE/INGERIDO/FALHOU`) + `azads_gastos` (dia × campanha × produto, **snapshot**: `azads_replace_gastos` substitui a janela — merge deixaria valor morto). Cron `azads-diario` 03:45 BRT (colhe + pede D-3..D-1; flutuação de ~72h coberta pela re-pedida) e `azads-colher` 04:25 BRT; log em `ml_cron_log`. **Validação (item 6): API = painel 0,000%** (julho R$ 14.125,85 exato, cliques 18.927 idênticos). Card lê `azads_ads`; gráfico diário via `dre_diario_canais` (ramo az, full join). Migrations `20260730120001`, `20260803120001/130001/140001/150001`. Histórico API: SP ~95d, SB/SD ~60d — backfill além disso não existe. Detalhe: `AMAZON_ADS_DESCOBERTA.md`.
- **SHEIN (MVP 07/08/2026 — credencial integrada, ingestão NÃO construída)** — prefixo `shein_`. Modelo de auth ≠ OAuth dos demais: **NÃO existe refresh token**. appid+appSecretKey (Vault `shein_app_id`/`shein_app_secret`) → seller autoriza a app → `tempToken` (curto, uso único) → `shein_exchange_token()` chama `/open-api/auth/get-by-token` (assinatura modo APP) e recebe **openKeyId + secretKey de LONGA DURAÇÃO** (openKeyId → `shein_oauth_state`; secretKey decriptado AES-128-CBC chave=16 primeiros bytes do appSecret, IV `space-station-de` → Vault `shein_secret_key`). Assinatura de API (validada 1:1 contra o SDK oficial `sheinsight/open-sdk-java`): `x-lt-signature = randomKey(5) || base64(hex(hmac_sha256(keyId&timestamp_ms&path, secret||randomKey)))` — timestamp em **milissegundos**; base64 do PG solta `\n` (removido). Edge: **`shein-oauth-callback`** (recebe tempToken, GET ou POST) e **`shein-token`** (gateway x-api-key `shein_token_key`; `?path=` devolve headers assinados). `shein_refresh_token()` é validador honesto de custódia (sem cron keepalive — nada expira). Card no dashboard: bruta + CMV reais (`shein_faturamento`/`shein_cmv`, tabelas `shein_pedidos`/`shein_itens` com vigência de CMV); deduções null e M.C. suprimida ("MVP — deduções na fase 100%", REGRA DURA). Fase 100%: ingestão de pedidos/itens + deduções de settlement + cron. Migration `20260807150001_shein_oauth`.
- **B2B (Tiny)** — notas fiscais do Tiny (`b2b_notas`/`b2b_itens`). Discriminador do canal B2B (o `/notas` do Tiny devolve TODAS as NFs, marketplace incluso): **`ecommerce` vazio + `tipo` "S" + `naturezaOperacao` "Venda%"** (exclui devolução de compra e remessa/bonificação). Ingestão: `b2b_fill_notas(de, ate, off_start, max_pages)` — em lotes. **NÃO tem cron: ingestão manual** (só `tiny-token-keepalive` existe). (Verificado 28/07/2026.)
- **Omie (despesas → DRE Grupo R)** — cron `omie-diario` (`omie_fill_despesas`: re-sync completo das contas a pagar) + `omie-semanal` (conta corrente `omie_fill_movimentos` + fornecedores). Classificação do DRE: linha vem do **PROJETO** (`omie_projeto_dre`), fallback **categoria** (`omie_dre_mapa`); include/exclude por categoria. **PIS/COFINS** (2.06.03→I3, 2.06.04→I4) e **DIFAL** (2.06.94→I1) entram acima da M.C.; competência dos impostos = mês do vencimento −1. Detalhe no Notion.
  - **[EM REVISÃO] PIS/COFINS entra acima da M.C. desde `91b76b3` (23/07/2026).** Supera a decisão anterior de deixar a carga tributária completa (PIS/COFINS/ICMS próprio/IRPJ/CSLL) para o módulo de Impostos futuro. **EM REVISÃO — não alterar sem decisão do Luciano.**
  - **Processo humano (origem da classificação do DRE):** a **Fernanda concilia** todos os gastos no Omie; o **Diego classifica cada lançamento do Omie numa linha do DRE** (e confere os canais contra os números que já tem). O Hub automatiza essa classificação via `omie_projeto_dre`/`omie_dre_mapa`. ⚠️ A régua da equipe no ML é **caixa/fatura do mês, não competência** — origem de divergência (ver Convenções). Fonte: página "DRE:" do Notion (13/07/2026).

### Billing ML — o que NÃO entra no cálculo (sub_types)

⚠️ **Não recontar.** 3 dos 4 maiores "créditos ignorados" do ML eram dupla contagem ou pass-through. **Achar um crédito é fácil; provar que ainda não está contado é o trabalho** (metodologia em `LICOES.md`).

- **`CFONPN` (taxa de parcelamento) — NÃO entra.** Pass-through net-zero: equivale ao acréscimo que o comprador pagou; receita e taxa se anulam. Ingerir só o custo deixaria a M.C. ~R$154.775 **pessimista**.
- **`CVVPRC` + `CVVFNU` — NÃO entram.** Já dentro do `sale_fee` (`sale_fee = CVVML + CVVPRC + CVVFNU`, provado pedido a pedido). Entrar = dupla contagem ~R$40k.
- **`BVVML` / `BFFE` / `BVVPRC` / `BVVFNU` (estornos) — NÃO entram.** A régua `paid + partially_refunded` já trata (venda cancelada sai inteira); creditar o estorno por cima = dupla contagem.
- **`CXDE` — é FRETE, não fricção.** O ML migrou `CFFE`→`CXDE` ~24/06/2026; o frete do Hub vem da API de shipments. Entrar = +R$61k de dupla contagem.
- **`BPAD` — ENTRA, credita o ADS.** `ADS líquido = ADS bruto − BPAD` (o gasto vem bruto da API de delivery; o ML bonifica parte na fatura).
- **`CV` — AGUARDANDO VERIFICAÇÃO.** Confirmar por pedido se está dentro do `sale_fee` **antes** de decidir; **não excluir por materialidade** (ver Pendências).
- Já tratados (o "bloco 7" do billing): `CFWA`/`CFCBE`→Full, `CPAC`/`CESM`→R6 (`4a60520`), `CCOLPA`→Full/C7 (`fd93041`).

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

- 🛑 **REGRA DURA — nenhum custo ou dedução é estimado, arbitrado ou preenchido por percentual. Tudo vem da API.** Se o dado ainda não existe, o número **não é exibido como se existisse** — mostra-se a **cobertura** (quantos pedidos têm o dado real), nunca uma aproximação. Isso **encerra** a opção de versionar a estimativa do `tt_deducoes` (e qualquer equivalente). (Luciano, 28/07/2026.)
- **Piso de cobertura (exibição da M.C.)** — operacionaliza a REGRA DURA. `PISO_COBERTURA = 0.80` em `lib/data/supabase.ts`, **uma régua só para TikTok e Shopee**. Cobertura = **ponderada por receita** (Σ receita liquidada / Σ receita paga), não por contagem de pedidos.
  - **Abaixo do piso:** o card **não exibe M.C.** — mostra bruta, CMV e margem bruta (todos reais, medidos 100% desde a venda), deduções "aguardando liquidação", e "cobertura X% — em consolidação" no lugar da M.C. Nunca apaga o canal, nunca inventa número.
  - **Acima do piso:** a M.C. sai sobre o **subconjunto liquidado dos DOIS lados** (receita liquidada − deduções liquidadas − CMV liquidado). **Nunca líquido cheio contra dedução parcial** — isso é o mesmo descasamento do `+R$1.095` do TikTok, só menor: a 80% de cobertura ~1/5 da receita fica sem custo (no TikTok pode passar de R$500 num mês cuja M.C. inteira oscila nessa ordem). A 100% os dois caminhos coincidem, então a diferença só existe **na faixa onde o erro passaria batido**.
  - **80% é valor INICIAL por julgamento, NÃO calibrado** — revisar após um ciclo completo com variância medida.
  - **Por que não extrapolar o subconjunto:** liquida primeiro quem é mais **antigo** e tem **menos devolução** → o subconjunto liquidado é enviesado pra cedo; escalá-lo para o mês inteiro seria inventar. Por isso mostra-se cobertura, não projeção.
- **CLAUDE.md é a fonte de verdade; Notion é espelho.** Ao mudar regra/arquitetura, atualizar aqui primeiro.
- **Toda sessão termina com commit + push** e confirmação por escrito (nº de commits, SHA do HEAD remoto, working tree limpo/sincronizado).
- **Conflito de informação:** reportar o conflito ao Luciano; **não escolher sozinho** qual está certa.
- **`proxy.ts` na raiz é o correto no Next 16 — substitui o `middleware.ts`. A ausência de `middleware.ts` é ESPERADA, não é bug.** Exporta `proxy(req)` + `config` (matcher). Faz o gate de acesso: em produção exige o cookie `hub_auth`; em `localhost` libera sem gate.
- **`AGENTS.md`** (importado no topo deste arquivo) = regras do **Next 16** para agentes (ler `node_modules/next/dist/docs/` antes de escrever código Next). **`README.md`** é boilerplate do create-next-app (ignorar).
- **`APRENDIZADOS_SHOPEE_ML.md`** = guia histórico de ingestão **só de ML e Shopee**. Útil para as "pegadinhas" de auth/escrow/billing, mas **incompleto/defasado** — ver divergências abaixo. Não copiar cego.

- **Atribuição por COMMIT, não por memória da conversa.** Esta conversa atravessa vários dias e é compactada — **"esta sessão" e "hoje" NÃO são confiáveis**. Trabalho realizado e autorização se provam por **commit (SHA + data)**. Ao afirmar que algo foi feito ou pedido, citar o SHA e a data; se não achar registro, dizer isso.
- **A equipe fecha por CICLO DE FATURA; o Hub fecha por MÊS-CALENDÁRIO.** Não é erro de nenhum lado — é régua diferente (a equipe pega o ML por **caixa/fatura**; o Hub por **competência/mês**), e explica a maior parte das divergências.
- **Toda mudança de régua exige backfill.** Ao mudar uma régua, perguntar: *que dado já ingerido está na régua antiga, e a janela do cron alcança ele?* Se não alcança, backfill **não é opcional** — a mudança da régua da bruta da Shopee (13/07) deixou 01–06/07 órfão, faltando 56% dos pedidos.
- **`LICOES.md`** = lições de metodologia + achados (detectores CMV/bruta ~68% e "0-cancelados"; 3 estados da honestidade no log; bug "gatilho que nunca re-tenta"; `CDLIT`=Seguidores). Números lá são referência histórica, não verdade viva.

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
- ✅ **RESOLVIDO (28/07/2026) — Régua das deduções dos não-liquidados (TikTok e Shopee).** Decisão do Luciano: **nada estimado** (REGRA DURA). **TikTok:** drift removido, `tt_deducoes` de volta a settled-only + piso de cobertura (`20260728120001`). Teste ao vivo provou que o dado de dedução não existe antes de liquidar (order detail sem `fee_breakdown`). **Shopee:** hipótese do "escrow ignorado" **descartada** — varredura 28/07 mostrou **100% de cobertura de escrow em jun e jul, zero ocorrências**; a assimetria teórica (bruta conta os não-cancelados, dedução só quem tem escrow) **não morde** porque o escrow chega no `READY_TO_SHIP`. Blindagem preventiva do `SUM(NULL)→0` na régua viva (`sp_repasse`) + cobertura, régua inalterada (`20260728120002`). Órfãs `sp_comissao`/`sp_frete` marcadas com `COMMENT ON FUNCTION` (não alimentam o app).
- **Rotina de diff repo↔banco (proposta, não implementada):** comparar `pg_get_functiondef` de cada função contra o texto versionado nas migrations e **alertar quando divergirem** — a convenção "atribuição por commit" **não pega** drift aplicado direto no banco (foi assim que o `tt_deducoes` divergiu sem SHA).
- **Conciliação bancária = processo MANUAL (não há módulo).** Extrai do Omie em `.xls` (+ extrato OFX) → concilia fora → devolve ao Omie em `.xls`; envolve a **Cristiane**. A automação (retirada/envio do xls via token/refresh no Supabase) nunca saiu do papel — por isso o módulo de Conciliação Bancária não existe. (Página "CONCILIAÇÃO BANCÁRIA:" do Notion.)
- ✅ **RESOLVIDO (03/08/2026) — Amazon ADS deixou de ser R$0 hardcoded.** Advertising API integrada de ponta a ponta: OAuth autorizado (callback Edge `amazon-ads-callback`, plano B da Vercel pausada), **item 6 bateu 0,000%** (API R$ 14.125,85 = painel R$ 14.125,85, julho/2026, cliques idênticos 18.927), julho backfillado em `azads_gastos` e card + DRE topo + gráfico diário ligados no dado real. Crons `azads-diario`/`azads-colher` ativos. Detalhe completo em `AMAZON_ADS_DESCOBERTA.md`. Pendência residual: comparar relatório × **fatura** (impostos) quando a primeira fatura com ADS fechar.
- **`CV` (billing ML)** — verificar por pedido se está dentro do `sale_fee` **antes** de excluir; não por materialidade (ver bloco "Billing ML — o que NÃO entra").
- **Detector de "dia com 0 cancelados" NÃO construído** — pegaria buracos de captura semanas antes (ver `LICOES.md`).
- **Bug latente:** DIFAL Shopee grava `create_date` em **UTC**, não BRT — cobrança no último dia do mês à noite cai no mês seguinte. Fix: `AT TIME ZONE 'America/Sao_Paulo'`.
- **Robustez do cron da Amazon nunca auditada** (log honesto/alerta/gatilho) — e `az_settlement` incompleto (3/7; a Amazon posta em 2 settlements com ~9 dias de diferença): candidato ao bug "gatilho que nunca re-tenta".
- Menores: `seguidores` sem conferência de contagem; root-cause do timeout do `reconferirDia` (ML, paginar por pendentes).
