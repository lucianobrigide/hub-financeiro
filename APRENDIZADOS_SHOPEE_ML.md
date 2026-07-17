# APRENDIZADOS — Integração Financeira Mercado Livre & Shopee

> **Propósito deste arquivo.** Documento auto-contido para outra instância de IA reconstruir do zero um Hub Financeiro de e-commerce que puxa **pedidos e financeiro** de marketplaces e monta uma DRE por canal (faturamento → deduções → margem de contribuição). Foi escrito a partir da análise completa do código-fonte (migrations SQL, Edge Functions Deno, camada de dados TypeScript, histórico de commits) e da documentação técnica registrada no Notion do projeto. **Você (o leitor) não terá acesso ao código original — tudo o que importa está aqui.**
>
> **Acesso ao Notion:** SIM, tive acesso ao workspace via MCP e incorporei as "pegadinhas" e decisões travadas documentadas lá (em especial a doc técnica "Módulo 02 — Ingestão ML" §8.2/§8.3 e as subpáginas de DRE/Margem).
>
> **Segurança:** este arquivo **NÃO contém nenhuma credencial real** — nenhum token, `client_secret`, `partner_key`, `seller_id`, `shop_id`, `client_id`, redirect URL de produção ou chave. Onde um valor sensível existiria, aparece `<REDACTED>` ou uma descrição do formato. Ao reconstruir, guarde segredos apenas em cofre (Vault) / variáveis de ambiente.

---

## 0. CONTEXTO E ARQUITETURA GERAL (comum aos dois marketplaces)

### 0.1 O negócio
E-commerce 100% online de panelas (cookware), regime **Lucro Real**, logística de fulfillment (Full/FBA). Vende em múltiplos canais: **Mercado Livre (principal), Shopee**, TikTok Shop, Amazon, Vendas Internas. O objetivo do Hub é responder, por canal e por mês fechado: **quanto entrou de fato (líquido) e qual a margem de contribuição real**, descontando comissões, tarifas, frete subsidiado, ADS, impostos (DIFAL), afiliados, devoluções e CMV.

### 0.2 Stack
- **Front/app:** Next.js (App Router) + TypeScript + Tailwind. Deploy contínuo (push → build).
- **Banco/back:** Supabase (Postgres gerenciado). **Toda a lógica pesada vive no banco**: RPCs em PL/pgSQL, extensões `http` (cliente HTTP dentro do Postgres), `pg_cron` (agendador), `pgcrypto`/`hmac` (assinatura), Supabase **Vault** (`vault.secrets`) para segredos.
- **Edge Functions (Deno):** usadas só como (a) gateway fino de leitura de token e (b) motor de ingestão quando o trabalho excede o limite de tempo de um statement de banco.

### 0.3 Cinco decisões arquiteturais que se pagaram (adote todas)

1. **HTTP a partir de dentro do Postgres.** A extensão `http`/`extensions.http()` permite fazer `GET`/`POST` às APIs dos marketplaces direto de uma função SQL. Vantagens: (a) o segredo (`partner_key`, `client_secret`) **nunca sai do banco**; (b) você testa uma chamada de API inteira num único `SELECT` (com CTE); (c) o IP de saída é estável (o do projeto Supabase) — dá para **whitelistar esse IP** no Partner Center da Shopee. Limitação: o worker do `pg_cron` **cancela statements em ~2 min** por padrão — para jobs longos, prefixe o comando agendado com `SET statement_timeout = '45min';` (ou `'900s'`). Trabalho realmente pesado (varrer milhares de pedidos) migra para Edge Function.

2. **Custódia de segredo em Vault, estado quente em tabela singleton.** O `refresh_token` (que **rotaciona** nos dois marketplaces) e as chaves de app vivem **só** no `vault.secrets`. Uma tabela `*_oauth_state` com **uma linha `id=1`** guarda o `access_token` em cache + `expires_at` + metadados não-sensíveis. Nunca guarde `refresh_token` em tabela comum.

3. **RLS ligado, zero policies, tudo por RPC `SECURITY DEFINER`.** Toda tabela tem `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` **sem nenhuma policy**. Todo acesso passa por funções `SECURITY DEFINER` com `REVOKE ALL ... FROM public, anon, authenticated` + `GRANT EXECUTE ... TO service_role`. Motivo prático descoberto: dependendo da configuração de API keys, o `service_role` **não fura RLS num SELECT direto via PostgREST** — então leitura vira RPC também (ex.: `ml_get_state()`, `shopee_get_state()`).

4. **Camada `dataProvider` única entre UI e dados.** Nenhum componente de UI importa dados direto. Existe `lib/data/` com `types.ts` (contratos), `mock.ts` (default), `supabase.ts` (real) e `index.ts` que escolhe a fonte por env var (`DATA_SOURCE=supabase`). **Regra de ouro:** sem dado real → `null` ("sem dados ainda"), **nunca zero inventado**. Dashboard abre no **último mês FECHADO**, nunca no mês corrente parcial. (Pegadinha de deploy: se a env `DATA_SOURCE` não estiver setada em produção, o site serve o mock silenciosamente — parece "dados zerados".)

5. **Idempotência por chave natural + reconferência.** Toda ingestão é `UPSERT ... ON CONFLICT (pk) DO UPDATE/NOTHING` sobre a chave natural do recurso (id do pedido, id do detalhe de billing, id do envio). Isso permite reprocessar qualquer janela quantas vezes quiser sem duplicar. Além do "fechar ontem", há uma **reconferência** periódica (7 e 30 dias) que relê e atualiza status/valores que mudaram (cancelamentos, reembolsos, ajustes de repasse).

### 0.4 Padrão de custódia OAuth (idêntico nos dois marketplaces)
```
┌─ Vault (vault.secrets) ─────────────────────────┐
│  <mp>_client_id / partner_id                     │  segredos, nunca em tabela
│  <mp>_client_secret / partner_key                │
│  <mp>_refresh_token   (ROTACIONA a cada refresh) │
│  <mp>_token_key       (x-api-key do gateway)     │
└──────────────────────────────────────────────────┘
        │ lido só por funções SECURITY DEFINER
        ▼
┌─ public.<mp>_oauth_state  (singleton id=1) ─────┐
│  access_token (cache) · expires_at · metadados   │  RLS on, sem policy
└──────────────────────────────────────────────────┘
        │
        ▼
┌─ Edge Function <mp>-token (gateway fino) ───────┐
│  valida x-api-key → get-or-refresh → devolve     │
│  access_token válido (ou params já assinados)    │
└──────────────────────────────────────────────────┘
```
A função de refresh é protegida por **advisory lock de transação** cobrindo a chamada HTTP inteira, e **grava o refresh_token novo no Vault ANTES de qualquer outra coisa** (ordem importa: se o token rotacionou, perder o novo = quebrar a cadeia).

### 0.5 Numeração de advisory locks (para não colidir)
Cada canal tem seu número. Refresh e cron usam números diferentes:

| Canal | lock refresh (xact) | lock cron (session) |
|---|---|---|
| Mercado Livre | `421982731` | `421982739` |
| Shopee | `421982735` | `421982738` |
| TikTok | — | `421982737` |

Refresh usa `pg_advisory_xact_lock` (cai no commit/rollback, cobre o HTTP). Cron usa `pg_try_advisory_lock` (lock de **sessão** — cada job `pg_cron` roda em backend próprio e o lock cai ao fim; se não conseguir pegar → `skipped: already_running`). **Armadilha testada:** `pg_try_advisory_lock` é **re-entrante na mesma sessão** — testar concorrência de uma única conexão dá **falso positivo**; teste com 2 sessões reais.

---

# ═══════════════════════════════════════════════
# PARTE A — MERCADO LIVRE
# ═══════════════════════════════════════════════

## A1. AUTENTICAÇÃO E CREDENCIAIS (Mercado Livre)

### A1.1 Endpoints e grants
- **Token:** `POST https://api.mercadolibre.com/oauth/token` — `Content-Type: application/x-www-form-urlencoded`, `Accept: application/json`. `client_id` e `client_secret` vão **no body** (padrão ML), não em header.
- **Grant inicial:** `grant_type=authorization_code` (rodado uma vez, na rota de callback do Next.js).
- **Grant de rotação:** `grant_type=refresh_token` (rodado pela função Postgres de refresh).
- **Identidade:** `GET https://api.mercadolibre.com/users/me` (Bearer) — usado só uma vez para capturar o `user_id` (= seller id) quando ainda desconhecido.
- **Autorização (consentimento):** `https://auth.mercadolivre.com.br/authorization?response_type=code&client_id=<REDACTED>&redirect_uri=<REDACTED>` (site = `MLB` para o Brasil).

### A1.2 Tempo de expiração — a pegadinha nº 1
- O `access_token` do ML dura **6 horas** (`expires_in ≈ 21600s`). **A doc antiga dizia 6h, mas o comportamento operacional é o que vale** — trate como ~6h e sempre com margem.
- O **`refresh_token` é de uso único e ROTACIONA**: cada chamada de refresh devolve um `access_token` novo **e um `refresh_token` novo**. Se você não persistir o refresh novo (e persistir **antes** de tudo, atomicamente), a cadeia quebra e cai em `invalid_grant` — aí só reautorização manual resolve.

### A1.3 Como o refresh automático foi resolvido (função Postgres)
Função `ml_refresh_token(p_force boolean)`, `SECURITY DEFINER`, `search_path = public, extensions, vault`:
1. `pg_advisory_xact_lock(421982731)` — serializa qualquer refresh concorrente e **cobre a chamada HTTP inteira** (liberado no commit).
2. Margem de folga: se `expires_at > now() + 30min` (ou `now() + 10min` se `p_force`), retorna `{refreshed:false, valid:true, reason:'cache_hit'}` **sem rotacionar** (evita gastar refresh_token à toa).
3. Lê `client_id`, `client_secret`, `refresh_token` **só do Vault** (`vault.decrypted_secrets`). Guardas fail-closed: sem credencial → `missing_credentials`; refresh nulo ou sentinela `__SET_ME__` → `refresh_token_not_seeded`.
4. `http_set_curlopt('CURLOPT_TIMEOUT_MS','15000')`; `POST` refresh.
5. Em `status=200` e body com `access_token`, **na mesma transação (atômico), nesta ordem:**
   1. **grava o `refresh_token` NOVO no Vault** (`vault.update_secret(...)`) — antes de qualquer outra coisa;
   2. captura `user_id` via `/users/me` só se ainda nulo;
   3. atualiza `ml_oauth_state` (`access_token`, `token_type`, `scope`, `expires_at = now() + expires_in`, `refreshed_at`, `user_id`);
   4. loga em `oauth_refresh_log` **sem valores sensíveis**.
6. `invalid_grant` → **não insiste**: loga "requer reautorização manual" e retorna `action:'reautorizacao_manual_necessaria'`.

### A1.4 Callback inicial (rota Next.js `/api/auth/callback`)
Roda uma vez para semear a cadeia. Recebe `?code`; troca por tokens via `authorization_code`; chama a RPC de seed (`ml_seed_initial`) que grava `client_id`/`secret`/`refresh_token` no Vault e o `access_token` inicial em `ml_oauth_state`. **Nenhum token volta na resposta HTTP** (tudo server-side). Redireciona `/?auth=success|error`.

### A1.5 Gateway de leitura (Edge Function `ml-token`)
- Autentica por header `x-api-key`, validado contra o Vault por RPC `ml_token_check` (fail-closed se a chave for nula/vazia/sentinela). Sem match → `401`.
- Caminho quente: lê o estado (RPC, não SELECT direto); se `expires_at - now > 10min (SKEW)`, devolve o token cacheado.
- Senão delega a `ml_refresh_token(false)` e relê. `409` para `invalid_grant`; `502` para outras falhas.
- **Cron de refresh proativo** (`ml-refresh-token`, `*/30 * * * *`) foi criado **INATIVO** — na prática o refresh acontece lazy dentro dos consumidores. Ative só se quiser aquecer o cache.

### A1.6 O que **NÃO** fazer
- Não guardar tokens em coluna de tabela comum (o projeto teve uma tabela `ml_tokens` assim e **descartou**).
- Não deixar o `client_secret` no código do front nem em migration — só Vault/env.

---

## A2. ENDPOINTS UTILIZADOS (Mercado Livre)

Wrapper de request com **backoff exponencial em HTTP 429** (ex.: 6 tentativas, `sleep(1000·2^n)`); erros não-429 viram um marcador de erro `{__err: status}`; timeout/rede também re-tenta.

### A2.1 Pedidos — `GET /orders/search`
Params: `seller={id}` + janela de data + `sort` + `offset` + `limit` (`limit=50`). Três modos:
- **Fechar o dia:** filtro `order.date_closed.from/to` cobrindo o dia inteiro em SP (`00:00:00.000-03:00` a `23:59:59.999-03:00`), `sort=date_asc`.
- **Reconferir (passe A):** filtro `order.date_last_updated.from/to`, `sort=date_asc`.
- **Reconferir (passe B):** `order.date_last_updated.from` + `order.status=cancelled`, `sort=date_desc`.

> **PEGADINHA CRÍTICA — cancelados escondidos:** a busca por vendedor com filtro de data **esconde pedidos cancelados** que saíram da janela. Por isso o **passe B explícito com `order.status=cancelled`** é obrigatório para capturar cancelamentos tardios. E `order.status=pending_cancel` como filtro dá **HTTP 400** — não use.

> **PEGADINHA CRÍTICA — teto de 10.000 no offset:** o `/orders/search` **não pagina além de offset 10.000** e **não existe "scan"/`search_type=scan` para orders** (existe para outros recursos, mas não este — foi tentado e não vale). Solução: quando `paging.total > 10000`, **subdivida a janela de tempo recursivamente pela metade** (24h → 12h → 6h → … até ~1h) até cada fatia caber sob 10k. Se ainda estourar em ≤1h, marque `cap=true` e registre.

Campos lidos do pedido: `id, date_closed, date_created, status, total_amount, currency_id, date_last_updated, context.channel, cancel_detail.date, shipping.id, pack_id, payments[].transaction_amount_refunded, order_items[]{item.id, item.variation_id, item.seller_sku|item.seller_custom_field, item.title, quantity, unit_price, sale_fee, currency_id}`.

### A2.2 Detalhe de pedido — `GET /orders/{id}`
Só para resolver `cancel_detail.date` de pedidos `cancelled`/`pending_cancel` (evita N+1 fora desses casos). `sleep(80ms)` entre chamadas.

### A2.3 Frete/envios — `GET /shipments/{id}` e `GET /shipments/{id}/costs`
Ambos com header **`x-format-new: true`**. Lê `senders[].cost` (o custo do **vendedor** = seu `user_id`), `receiver.cost`, `gross_amount`, `logistic_type`, `status`. **Frete é por ENVIO, não por unidade.** `sleep(60ms)` entre envios.

### A2.4 Publicidade (ADS) — família `/advertising/...`
- `GET /advertising/advertisers?product_id=PADS` (header `Api-Version: 1`) → pega o `advertiser_id`.
- `GET /advertising/MLB/advertisers/{adv}/product_ads/campaigns/search` (header `api-version: 2`), params `date_from/date_to`, `metrics=cost`, `aggregation_type=DAILY` → campo **`cost`** (Product Ads).
- `GET /advertising/advertisers/{adv}/brand_ads/campaigns/metrics` (`aggregation_type=daily`, `strategy=marketplace`) → campo **`consumed_budget`** (Brand Ads).
- `GET /advertising/MLB/advertisers/{adv}/product_ads/ads/search` (`api-version: 2`, `metrics=cost`) → ADS por **item** por dia (uma chamada/dia devolve todos os itens; soma por item bate ~99,9% com o total).

> **PEGADINHA — dia corrente é parcial:** capturar ADS do **dia corrente** devolve dado **pela metade** (a plataforma ainda está consolidando). **Só ingira dia fechado.** Além disso, a *delivery API* de Display Ads devolveu R$0 num mês em que o painel/billing mostrava ~R$4,5k — ou seja, ADS de Display aparece no **billing/faturado**, não na delivery. Trate ADS "de verdade" pelo billing quando divergir.

### A2.5 Billing (faturamento oficial do ML) — o endpoint mais traiçoeiro
Base: `GET /billing/integration/periods/key/{YYYY-MM-01}/group/ML/details` (e variante `.../full/details` para custos de fulfillment).
- **`document_type=BILL` é OBRIGATÓRIO** — sem ele, `HTTP 422`.
- Filtro por tipo é **`detail_sub_types` (PLURAL)**. O singular `detail_sub_type` é **ignorado silenciosamente** (devolve tudo). `order_id` como filtro também é **ignorado**.
- **Paginação por cursor `from_id` (EXCLUSIVO) + `sort_by=ID&order_by=ASC`.** `offset` é **ignorado** (offset alto devolve vazio); e o `last_id` que a própria resposta traz "pula à frente e derruba registros no fim da página" — então o cursor correto é o **`detail_id` do ÚLTIMO registro que você realmente leu**, não o `last_id` da resposta.
- Endpoint **lento**: exige `CURLOPT_TIMEOUT_MS` alto (o default de 5s do Postgres estoura). Rate-limita sob carga com `429 "Bloqueio preventivo por quantidade limitada de requests por IP"`.

`detail_sub_type` que importam (taxonomia do billing ML):
| Código | Significado | Uso na DRE |
|---|---|---|
| `CVAF` | Comissão de afiliados | dedução (Afiliados) |
| `CDIFAL` | ICMS-DIFAL interestadual | dedução (Impostos/DIFAL) |
| `CDLIT` | Campanha "Aumentar seguidores" | dedução (ADS/seguidores) |
| `BPAD` | **Bonificação** de Product Ads (crédito, vem **positivo**) | **abate** o ADS |
| `CFONPN` | Taxa de parcelamento | **IGNORAR** — pass-through net-zero (ver A3) |
| `CVVML/CVVPRC/CVVFNU` | Componentes de comissão de venda | **já dentro do `sale_fee`** — não somar |
| `CXDED/CDSDB/CFPB/CXDID` | Débitos de devolução/fricção | dedução (Custo Devoluções) |
| `BXDED/BDSDB/BXDID` | Créditos/estornos espelho | **abatem** os débitos acima |
| `CXDE` | **Frete** (o ML migrou `CFFE → CXDE` ~24/06) | **NÃO é fricção — é frete** (ver A5) |
| `WAREHOUSING/INBOUND_*/AGING` (na `/full/details`) | Custos de fulfillment (Full) | dedução (Full) |

### A2.6 Paginação — resumo dos erros cometidos
- `/orders/search`: **offset/limit** com teto de 10k → fatiar por tempo (não existe scan).
- `/billing/.../details`: **cursor `from_id` exclusivo**, ordenado por ID asc. Não confiar no `last_id` da resposta.
- Billing **trunca em silêncio** (ver A5) — sempre conferir contagem contra o `total`.

---

## A3. MODELAGEM FINANCEIRA (Mercado Livre)

### A3.1 As DUAS réguas de status (deliberadamente diferentes)
- **Régua do FATURAMENTO:** base = `status in ('paid','cancelled','partially_refunded')` (exclui `invalid`).
  - `Bruto = Σ valor_total` de toda a base (cancelado **conta na bruta**).
  - `Cancelamentos/Devoluções = Σ valor_total dos cancelled (inteiro) + Σ valor_reembolsado dos partially_refunded (só a porção reembolsada)`.
  - `Líquido = Bruto − Cancelamentos/Devoluções`.
- **Régua da MARGEM** (comissão, frete, CMV, DRE diário): `status in ('paid','partially_refunded')` — **exclui `cancelled`**. Por quê: comissão/custos de pedido cancelado são **estornados** pelo ML; contá-los de novo = dupla contagem. (Bug histórico: a versão inicial usava `status <> 'invalid'`, que **incluía cancelled** — errado.)
- Devolução **PARCIAL fica na base** da margem (abate só o reembolso). Devolução **TOTAL/cancelado sai** — o cálculo é ao vivo por status, **nada é congelado**.
- Dashboards descartam sempre o **dia corrente** (`data < hoje@SP`).

### A3.2 Competência e fuso
- Tudo em **America/Sao_Paulo (UTC−3)**. A coluna `data` do pedido = `date(date_closed @ SP)` = **data da venda**, não mês de faturamento.
- Cancelamento é atribuído pela **data do evento** (`cancel_detail.date @ SP`), não pela data da venda.
- Diferenças de timing (frete de fim de mês que posta no mês seguinte; billing por ciclo) **reconciliam no módulo de conciliação — não são erro**.

### A3.3 Comissão (`sale_fee`) — o campo que mais engana
- `sale_fee` vem **junto do pedido** (dentro de cada `order_item`), **CRU e POR UNIDADE**. A multiplicação por quantidade é feita **na leitura**: `Σ (sale_fee × quantidade)`. Nada é repopulado/derivado.
- O `sale_fee` **já engloba** os componentes `CVVML + CVVPRC + CVVFNU` do billing — provado ao centavo, pedido a pedido. **Somar CVVPRC/CVVFNU do billing = dupla contagem** (~R$40k/mês no caso real).
- **Comissão zerada num pedido ≠ isenção:** é **REBATE de campanha** (`funding_mode: sale_fee`). O rebate é grande (~R$170k/mês) e **rastreável por pedido no billing** (`sale_fee.gross/net/rebate` + `order_id`). Ao conciliar, some o gross e trate o rebate como crédito.

### A3.4 As deduções que compõem a M.C. (e como calcular cada uma)
Partindo do **Faturamento Líquido**, subtraia:
1. **Comissão:** `Σ(sale_fee × quantidade)`, régua margem.
2. **Frete:** `Σ custo_vendedor` dos envios (por `shipping_id`), régua margem. Só o frete de **entrega/ida** — o frete Full não entra aqui.
3. **Full / Fulfillment:** custos de armazenagem/coleta/penalidade da `/full/details`. **Sem régua de status.** Atribuição pela **`creation_date`** (dia real do lançamento), NÃO pela KEY do período (que mistura 2 meses).
4. **ADS (líquido):** `bruto − BPAD`, onde `bruto = Σ gasto` de Product Ads + Brand Ads + seguidores, e `BPAD` (bonificação, vem positivo no billing) **abate**.
5. **Afiliados (`CVAF`):** régua = **`creation_date`, mês-calendário** (decisão consciente — ver abaixo).
6. **DIFAL (`CDIFAL`):** ICMS-DIFAL interestadual, régua `creation_date`.
7. **Custo Devoluções / Fricção:** `Σ(CXDED,CDSDB,CFPB,CXDID) − Σ(BXDED,BDSDB,BXDID)` (débitos menos estornos-espelho).
8. **CMV:** `Σ custo × quantidade` (join da tabela de custos por SKU), régua margem.

`M.C. = Líquido − (1..8)`.

> **Por que afiliados/DIFAL usam `creation_date` e não a data da venda:** o `CVAF` é cobrado **em lote, meses depois** (venda em jan–abr → cobrança lançada em jun). Atribuir pela venda descasaria da fatura do ML. Escolheu-se casar com **o dia em que o ML lançou a cobrança** (mês-calendário), aceitando o descasamento com a competência de vendas (que reconcilia depois).

### A3.5 Ciclo de faturamento 23→22 (billing)
O ciclo de billing do ML fecha **~dia 22** (CVAF ~dia 15). Logo **um mês-calendário vem de DUAS faturas**: `creation_date 01–22` na fatura do mês, `23–fim` na fatura do mês seguinte. Por isso todo ingest de billing **pesca a KEY do mês corrente E a do mês anterior**, e guarda `periodo_key` (a KEY consultada) **separada** de `creation_date` (o dia real). A idempotência por `detail_id` garante zero sobreposição entre as duas faturas.

### A3.6 Valores que **parecem** receita/custo mas NÃO são (não redescobrir)
- **`CFONPN` (taxa de parcelamento):** é **pass-through net-zero**. No relatório oficial aparece como receita por acréscimo `+X` e taxa equivalente `−X` = 0,00 exato. Ingerir só o custo deixaria a M.C. artificialmente pessimista (~R$154k no caso real).
- **`CVVPRC/CVVFNU`:** já dentro do `sale_fee` (não somar).
- **`BVVML/BFFE/BVVPRC/BVVFNU`:** já tratados pela régua paid+partially_refunded (venda cancelada sai inteira).
- **`CXDE`:** é **FRETE**, não fricção (o frete já vem de `/shipments/costs`; somar CXDE = +~R$61k de dupla contagem).

### A3.7 Conciliar pedido ↔ repasse (ML)
O ML **não** tem um "escrow por pedido" tão explícito quanto a Shopee; a conciliação se faz cruzando **billing (por `detail_sub_type`/`order_id`) contra os pedidos**. As pontas que restam para o fechamento oficial: rebate de comissão (por pedido no billing), Display Ads (billing vs delivery), frete de devolução, timing competência × faturamento, seguidores/CDLIT (fecha ~dia 22).

---

## A4. ESTRUTURA DE DADOS (Mercado Livre)

Todas as tabelas: **RLS enable, sem policies**. Nomes/tipos exatos:

**`ml_oauth_state`** (singleton): `id int PK DEFAULT 1 CHECK(id=1)`, `account text`, `access_token text`, `token_type text`, `scope text`, `expires_at timestamptz`, `refreshed_at timestamptz`, `user_id text`, `updated_at timestamptz`. *(refresh_token NÃO fica aqui — vai no Vault.)*

**`oauth_refresh_log`**: `id bigint identity PK`, `conta text`, `http_status int`, `success bool DEFAULT false`, `message text`, `expires_at_novo bigint`, `created_at timestamptz`. Índice `(conta, id desc)`.

**`ml_pedidos`**: `pedido_id bigint PK`, `data date NOT NULL` (=date_closed@SP), `date_closed timestamptz`, `date_created timestamptz`, `status text NOT NULL`, `valor_total numeric(14,2)`, `valor_reembolsado numeric(14,2) DEFAULT 0`, `qtd_unidades int`, `canal text`, `moeda text`, `date_last_updated timestamptz`, `atualizado_em timestamptz`, `data_cancelamento date`, `shipping_id bigint`, `pack_id bigint`. Índices em `data`, `status`, `date_last_updated`, `data_cancelamento`, `shipping_id`.

**`ml_pedido_itens`**: PK composta **`(pedido_id, item_id, variation_id)`** (`variation_id bigint DEFAULT 0`); `sku text`, `titulo text`, `quantidade int`, `valor_unitario numeric(14,2)`, `sale_fee numeric(14,2)` (cru/por unidade), `moeda text`. FK → `ml_pedidos` ON DELETE CASCADE.

**`ml_devolucoes`**: `claim_id bigint PK`, `order_id bigint FK`, `return_id bigint`, `tipo text`, `reason_id text`, `claim_status text`, `resolution_reason text`, `status_money text`, `qtd_devolvida numeric`, `valor_reembolsado numeric(14,2)`, `date_created`, `last_updated`, `atualizado_em`.

**`ml_envios`**: `shipment_id bigint PK`, `custo_vendedor numeric(14,2)`, `custo_comprador numeric(14,2)`, `gross_amount numeric(14,2)`, `logistic_type text`, `cost_type text` (`free|charged|partially_free`), `status text`, `last_updated`, `atualizado_em`.

**`ml_ads_diario`**: PK `(data, produto)`; `produto text` (`product_ads|brand_ads|seguidores`), `gasto numeric(14,2)`.
**`ml_ads_item_diario`**: PK `(data, item_id)`, `gasto numeric`.

**`ml_full_faturamento`**: `detail_id bigint PK`, `creation_date date`, `creation_date_time timestamptz`, `tipo text`, `detail_sub_type`, `detail_amount numeric(14,2)`, `transaction_detail`, `concept_type`, `warehouse_id`, `sku`, `item_id`, `inventory_id`, `quantity numeric`, `amount_per_unit numeric(14,6)`, `legal_document_number` (a NF), `document_id bigint`, `periodo_key date`.

**`ml_afiliados`**: `detail_id bigint PK`, `creation_date date`, `creation_date_time`, `detail_sub_type` (=CVAF), `detail_amount numeric(14,2)`, `transaction_detail`, `order_id bigint`, `sale_date_time timestamptz` (venda original), `legal_document_number`, `document_id`, `periodo_key date`.

**`ml_difal`**: igual `ml_afiliados` + `marketplace text`; `detail_sub_type=CDIFAL`.

**`ml_billing_linhas`** (fatura completa/genérica): `detail_id bigint PK`, `creation_date date NOT NULL`, `creation_date_time`, `detail_type text` (CHARGE|BONUS), `detail_sub_type text NOT NULL`, `detail_amount numeric NOT NULL`, `transaction_detail`, `order_id bigint`, `periodo_key text` **(atenção: aqui é `text`, enquanto em `ml_afiliados`/`ml_difal` é `date` — essa inconsistência causou um bug, ver A5)**, `atualizado_em`.

**`ml_custo_produto`** (de-para de CMV, **compartilhada com todos os canais**): `sku text PK`, `modelo text NOT NULL`, `custo numeric NOT NULL` (valor cheio do produto), `origem text CHECK in ('confirmado','exato','proposto-prefixo')`, `atualizado_em`.

**`ml_cron_log`**: `id bigint identity PK`, `executado_em timestamptz`, `job text NOT NULL`, `dia_alvo date`, `sucesso bool NOT NULL`, `http_status int`, `pedidos int`, `valor numeric(14,2)`, `duracao_ms int`, `mensagem text`, `resposta jsonb`. Índice `(job, executado_em desc)`.
**View `ml_cron_saude`**: `distinct on (job)` do último run + `horas_atras` — base do semáforo de saúde.

### A4.1 Decisões de modelagem que funcionaram / foram refeitas
- **Funcionou:** `sale_fee` cru por unidade (multiplicar na leitura) — permite recalcular comissão ao vivo conforme o status muda, sem migração de dado.
- **Funcionou:** `periodo_key` separado de `creation_date` no billing (resolve o ciclo 23→22).
- **Refeito:** régua da margem passou de `status <> 'invalid'` (incluía cancelado) para `paid + partially_refunded`.
- **Refeito:** atribuição do Full passou da KEY do período para `creation_date`.
- **Inconsistência que sobrou:** `periodo_key` é `date` em umas tabelas e `text` em outra — gerou um bug de cast (A5). **Ao refazer, padronize o tipo.**

---

## A5. ERROS E LIÇÕES (Mercado Livre)

1. **Billing trunca em silêncio (o pior).** A API de billing pode devolver **50 de 250 registros com HTTP 200 e sem erro**. Sem conferir, o mês fica incompleto e a M.C. sai errada **sem aviso**. Solução: a função de fill caminha por `from_id`, **confere `count(*)` no banco contra o `total` da API e refaz o walk (idempotente) até bater**, com no máximo N tentativas, devolvendo `completo: true/false`.

2. **Não parar em página curta.** Sob carga o billing devolve páginas menores **no meio** da paginação. Pare só em página **vazia** (última) ou quando o cursor não avança — nunca em "página menor que o page_size". Tenha um backstop de nº máximo de páginas.

3. **Os 3 estados da honestidade** (lição central do log). Não confunda:
   - `ok=false` → o walk nem rodou (API fora) = **falha real**, alerta.
   - `verificado=false` → rodou mas não deu para ler o `total` = **"não sei"**, NÃO acuse incompleto.
   - `completo=t/f` → conferido de verdade contra a API = só alerta se `false`.
   - Bug real: a 1ª versão marcava `completo=false` quando a API não respondia, logando "INCOMPLETO" com o dado **inteiro** no banco (cry-wolf). Além disso a própria verificação (`total`) tem que ter **retry** — a mesma key devolveu 2499 e minutos depois NULL.

4. **Log honesto (fim das mentiras hardcoded).** Havia strings `'ok'` e `sucesso=true` **hardcoded**. Um passo (afiliados) falhava **HTTP 500 em 100% dos runs por 4 dias** e o log dizia "ok" — o CVAF ficou congelado sem ninguém notar. O 500 era **transitório** e a Edge abortava no 1º erro (`throw`) sem retry. Lição: o log tem que refletir o resultado real de cada passo; e um passo com erro transitório precisa de retry, não `throw`.

5. **Frete "fingindo terminar".** Quando a Edge falhava, uma variável `restam` virava `false` por `coalesce`, o loop saía **fingindo sucesso** com `gravados=0`. Corrigido: sair com erro real; estourar o guard de chunks com pendentes = falha; contar dias que falharam na reconferência.

6. **Divergência repo ↔ banco.** Um fix de log honesto **só existia no banco, não no repo** — um replay das migrations reintroduziria o bug. Lição: **capture funções ao vivo com `pg_get_functiondef` e versione** (paridade banco↔repo). Faça varredura de segredos em todo commit.

7. **Bug de cast `periodo_key`.** `where periodo_key in ($1,$2)` com `$1/$2 text`, mas `periodo_key` é `date` em `ml_afiliados`/`ml_difal` → `date = text` lançava exceção **não tratada que derrubava o cron diário inteiro** no passo de afiliados (DIFAL/billing/reconferência pararam junto). Rodou ok por dias e só quebrou depois de um deploy. Denunciado pela **página de Crons** (o semáforo vem do `pg_cron`, não do log da app). Fix: `periodo_key::text` — e padronizar o tipo.

8. **Chamada da Edge tolerante a falha.** Um passo estourou 150s sob rate-limit 429; a exceção de `extensions.http()` propagava e **abortava o cron inteiro**. Fix: `begin/exception when others` captura timeout/rede → retorna `{http_status:0, error:'edge_call_falhou'}` logável; o passo é **repescado no próximo run** (auto-cicatrizante). O orquestrador **loga e segue, nunca aborta**.

9. **Advisory lock que faltava.** O ML era o único cron **sem lock** — um run manual encavalava com o das 03:00 (2 backends martelando a API que já rate-limita). Passos idempotentes não corrompem, mas dobram a carga. Adotado `pg_try_advisory_lock(421982739)` (lock de sessão).

10. **`statement_timeout`.** O worker do `pg_cron` cancela statements aos **2 min**; o fluxo leva ~10–15 min. Solução: `SET statement_timeout = '45min';` no comando agendado; funções de billing setam `'300s'` internamente.

11. **`limit` do billing calibrado empiricamente.** `limit=500` estourava timeout da API; `limit=150` dava **parse flaky** em respostas de ~230KB; **`limit=50`** (respostas ~77KB) ficou confiável. Retry **por página** (3×) — antes uma falha na 1ª página matava tudo.

12. **Alerta de saúde com N=2.** Só alerta após **2 dias seguidos** falhando (1 dia pode ser blip/429). Some sozinho quando o passo volta. Também expõe cobertura de CMV (SKU vendido sem custo some do CMV silenciosamente).

13. **Infra em chunks.** Edge cancela em ~150s (IDLE_TIMEOUT) → trabalho em chunks/por-dia. Frete é ingerido por **"pendentes da janela trailing"** (shipping_ids da janela recente que ainda não estão em `ml_envios`), não "só ontem" — porque **o custo de frete posta com atraso** (~R$44k de junho postou em julho).

### A5.1 O que eu faria diferente (ML)
- Padronizar `periodo_key` como `date` em todas as tabelas desde o dia 1.
- Nascer com os "3 estados da honestidade" e log fiel — não hardcodar sucesso nunca.
- Nascer com advisory lock, `statement_timeout` e Edge tolerante a falha em todos os crons.
- Guardar a linha crua de **todo** billing (`ml_billing_linhas`) desde o início, para poder conferir contagem em qualquer `detail_sub_type` (o passe de "seguidores" agrega por dia e não dá para conferir por contagem).

---

# ═══════════════════════════════════════════════
# PARTE B — SHOPEE
# ═══════════════════════════════════════════════

## B1. AUTENTICAÇÃO E CREDENCIAIS (Shopee)

Plataforma: **Shopee Open Platform** (Partner Center). Host de API: `https://partner.shopeemobile.com`. **Todo o tráfego HTTP sai de dentro do Postgres** — o IP do banco fica whitelistado no Partner Center e o `partner_key` nunca sai do banco.

### B1.1 Segredos (Vault)
`shopee_partner_id`, `shopee_partner_key` (App Key/Secret), `shopee_refresh_token` (rotaciona), `shopee_token_key` (x-api-key do gateway). Seed inicial do refresh usa sentinela `__PLACEHOLDER__` — a função de refresh recusa até o app ser autorizado (`refresh_token_not_seeded`).

### B1.2 Assinatura HMAC-SHA256 — DUAS base strings (pegadinha central)
Cada request Shopee precisa de `sign = hex(hmac_sha256(base_string, partner_key))`. **A base string tem duas formas** conforme o tipo de API:
- **Public API** (`auth_partner`, `token/get`, `access_token/get`): `base = partner_id + path + timestamp`.
- **Shop API** (todas as chamadas de dados): `base = partner_id + path + timestamp + access_token + shop_id`.

`timestamp` = epoch em **segundos**. **Use `clock_timestamp()`, não `now()`** para gerar o timestamp (ver B5) — `now()` congela na transação e a assinatura expira no meio de loops longos.

### B1.3 Funções (todas `SECURITY DEFINER`)
1. `shopee_auth_url()` → monta URL assinada de `/api/v2/shop/auth_partner` com `redirect` (urlencoded) para a Edge de callback.
2. `shopee_exchange_code(p_code, p_shop_id)` → `POST /api/v2/auth/token/get` (body JSON `{code, shop_id, partner_id}`). Salva access em `shopee_oauth_state`, grava refresh no Vault. **`expire_in` default 14400s (4h)**; `refresh_expires_at = now() + 30 dias`.
3. `shopee_refresh_token(p_force bool)` → `POST /api/v2/auth/access_token/get` (body `{refresh_token, shop_id, partner_id}`). Protegido por `pg_advisory_xact_lock(421982735)`. Margem: 30 min (5 min se `p_force`); cache-hit não rotaciona. **A Shopee TAMBÉM rotaciona o refresh_token** → regrava o novo no Vault. Falha explícita → `action: reautorizacao_manual_necessaria`.
4. `shopee_signed_params(p_path)` → devolve `{partner_id, timestamp, access_token, shop_id, sign}` (base string shop-level) para a Edge montar a URL.
5. `shopee_get_state()` / `shopee_token_check(key)` — leitura sem segredos / validação de x-api-key.

`CURLOPT_TIMEOUT_MS = 15000`.

### B1.4 Expiração e keepalive
- `access_token` dura **~4 horas** (14400s). `refresh_token` dura **~30 dias** (renova a janela a cada uso). Se o refresh_token expirar sem uso, precisa reautorizar.
- **Cron keepalive** `shopee-token-keepalive` (`15 */3 * * *`, a cada 3h) chama `shopee_refresh_token(false)`. Racional: access dura 4h, margem 30 min; se uma rodada falhar sobram ~3h de folga → auto-cicatrizante. O refresh primário é on-demand pela Edge.

### B1.5 Edge Functions (gateway fino)
- `shopee-oauth-callback`: recebe `code`+`shop_id` do redirect, delega a `shopee_exchange_code`. Não toca no `partner_key`.
- `shopee-token`: porta get-or-refresh. Valida `x-api-key` (`shopee_token_check`, 401 se falha), `SKEW = 30min`; se stale chama refresh e relê. Com `?path=`, retorna os params já assinados.

---

## B2. ENDPOINTS UTILIZADOS (Shopee)

Helper `_sp_api_get(path, extra, ...)` que gera timestamp com `clock_timestamp()`, monta `?partner_id&timestamp&access_token&shop_id&sign` + `extra`, e trata `http_<status>`, `invalid_json` e erro embutido `{error, message}`.

| Endpoint | Uso | Params-chave |
|---|---|---|
| `/api/v2/shop/auth_partner` | URL de autorização | public sign |
| `/api/v2/auth/token/get` | troca code→token | public sign |
| `/api/v2/auth/access_token/get` | refresh | public sign |
| `/api/v2/order/get_order_list` | listar pedidos | `time_range_field=create_time` (ou `update_time` na reconferência), `time_from/time_to` (epoch), `page_size=100`, `order_status` (ou omitido = todos), `cursor` |
| `/api/v2/order/get_order_detail` | detalhes + itens | `order_sn_list` (CSV, **máx 50/lote**), `response_optional_fields=item_list` |
| `/api/v2/payment/get_escrow_detail` | **repasse real** | `order_sn` (**1 por chamada**) |
| `/api/v2/ads/get_all_cpc_ads_daily_performance` | gasto CPC | `start_date/end_date` no formato **`DD-MM-YYYY`** |
| `/api/v2/payment/get_wallet_transaction_list` | DIFAL na carteira | `create_time_from/to`, `page_no`, `page_size=100` |

### B2.1 Limites e paginação (erros a evitar)
- **`get_order_list`: janela máxima de 15 dias** por chamada → fatiar o mês em janelas ≤15d.
- **Paginação de pedidos por CURSOR**, não offset: a resposta traz `more` (bool) + `next_cursor`. Itere enquanto `more=true`.
- **`get_order_detail`: máximo 50 `order_sn` por lote.**
- **`get_escrow_detail`: 1 pedido por chamada** — é o **gargalo de vazão** do sistema (ver B5).
- **ADS: range máximo de 1 mês** → o cron pesca 2 janelas (mês-a-data atual + mês anterior completo). Datas em `DD-MM-YYYY`.
- **Wallet: 15 dias por chamada, paginação `page_no`/`page_size=100`**, com guard de páginas.

---

## B3. MODELAGEM FINANCEIRA (Shopee)

Competência: **`create_time` em BRT (UTC−3), mês-calendário.**

### B3.1 Régua única — "não-cancelados"
Toda dedução e a bruta usam o **mesmo** filtro:
`order_status NOT IN ('CANCELLED','IN_CANCEL','UNPAID','INVOICE_PENDING')`.
Por quê (diferente do ML, que tem duas réguas): na Shopee **as deduções do escrow vêm "desde a venda"**, não só na conclusão — o `actual_shipping_fee` já vem líquido de subsídio (`shopee_shipping_rebate`) inclusive em `READY_TO_SHIP`. Cancelado sai limpo (some da bruta e do CMV).

### B3.2 ESCROW = a fonte de verdade do repasse (o conceito central da Shopee)
O `get_escrow_detail` (`order_income`) diz **quanto dinheiro efetivamente caiu** por pedido — já líquido de subsídio de frete, reembolso de voucher e ajustes. **Ancore a margem no repasse real, não em "preço − taxas brutas".**

> **BUG mais importante da Shopee:** a M.C. era reconstruída como "preço − taxas BRUTAS", **ignorando os créditos** que a Shopee devolve (subsídio de frete, reembolso de voucher). Ficava ~R$15,5k pessimista por mês — um mês real deu **−R$18.812** calculado assim, quando o **repasse real** dizia **−R$5.166**. Fix: expor `SUM(escrow_amount)` (o que caiu) e derivar a comissão/frete reais **como o que a Shopee de fato reteve**.

Campos do escrow lidos: `cost_of_goods_sold`, `net_commission_fee`, `net_service_fee`, `actual_shipping_fee`, `escrow_amount`, `escrow_amount_after_adjustment`, `buyer_total_amount`, `order_ams_commission_fee`.

### B3.3 Componentes da DRE Shopee (RPCs)
- `sp_faturamento` → `Σ selling_price` (bruta).
- **Comissão/frete reais** = `(bruta − repasse) − afiliados` — exatamente o que a Shopee reteve, já líquido de subsídio. (Também existem `sp_comissao = Σ(net_commission + net_service_fee)` e `sp_frete = Σ actual_shipping_fee` para detalhamento, mas a âncora é o repasse.)
- `sp_afiliados` → `Σ ams_commission` (campo escrow `order_ams_commission_fee` — AMS/afiliados).
- `sp_cmv` → `Σ custo × quantity` via join da tabela de custos por SKU (a **mesma `ml_custo_produto` compartilhada**, casando por `sku = unaccent(coalesce(nullif(model_sku,''), item_sku))` — `unaccent` por causa da cedilha).
- `sp_custo_devolucoes` → `Σ (escrow_amount − escrow_adjusted)` onde `escrow_adjusted < escrow_amount` = **custo incremental de devolução** (estorno já finalizado).
- **ADS** e **DIFAL**: separados do escrow (ver B3.4).

Aritmética final do card: `Líquido − comissão/frete real − ADS − Full − Afiliados − DIFAL − CMV − Devoluções = M.C.`

### B3.4 ADS e DIFAL — fora do escrow (zero dupla contagem)
- **ADS (CPC):** o escrow **não** contém ADS. Régua = data do gasto (competência diária), campo `expense` do CPC diário. **Achado real: a Shopee fica NEGATIVA no mês depois da mídia** (ex.: M.C. −R$21.409 num mês). (Nota: uma anotação antiga dizia "ADS pendente — precisa escopo Ads no Partner Center" — estava **ERRADA**; o escopo de Ads já vinha no token OAuth atual.)
- **DIFAL (ICMS interestadual):** cobrado **na CARTEIRA, não no escrow** (todos os campos de imposto do escrow por pedido = 0). Régua = `create_time` da transação de carteira. `amount` vem **negativo** (MONEY_OUT); o card usa o módulo. Tipo `ADJUSTMENT_CENTER_DEDUCT`, com dois `reason` ("Valor referente ao ICMS para Uf Destino (Difal)…" sistemático; "Débito por diferencial de alíquota… durante fiscalização" esporádico).

### B3.5 Conciliar pedido ↔ repasse (Shopee)
É mais direto que no ML: o **escrow por pedido** já é a conciliação. O que exige cuidado é **capturar o escrow de TODOS os pedidos** (o gargalo de 1 pedido/chamada) e **re-capturar o escrow definitivo** dos pedidos concluídos (o valor muda entre provisório e final após devolução/ajuste — ver B5).

---

## B4. ESTRUTURA DE DADOS (Shopee)

Todas RLS on, grants revogados de public/anon/authenticated, execute só `service_role`. **Nenhuma coluna JSONB persistida** — o JSON do escrow é consumido em memória e explodido em colunas tipadas.

```sql
shopee_oauth_state (
  id int PK CHECK(id=1), shop_id bigint, access_token text,
  expires_at timestamptz, refresh_expires_at timestamptz,
  refreshed_at timestamptz, updated_at timestamptz DEFAULT now())

shopee_pedidos (
  order_sn text PRIMARY KEY,
  create_time timestamptz NOT NULL,     -- competência BRT
  pay_time timestamptz,
  order_status text NOT NULL,
  selling_price numeric(12,2),          -- bruta (escrow cost_of_goods_sold OU Σ itens p/ não-COMPLETED)
  net_commission numeric(12,2),         -- escrow net_commission_fee
  net_service_fee numeric(12,2),        -- escrow net_service_fee
  shipping_fee numeric(12,2),           -- escrow actual_shipping_fee (líquido de rebate)
  escrow_amount numeric(12,2),          -- REPASSE real
  escrow_adjusted numeric(12,2),        -- escrow_amount_after_adjustment (pós-devolução)
  buyer_total numeric(12,2),            -- buyer_total_amount
  ams_commission numeric,               -- order_ams_commission_fee (afiliados)
  inserted_at timestamptz DEFAULT now())

shopee_itens (
  order_sn text REFERENCES shopee_pedidos(order_sn),
  item_id bigint, model_id bigint DEFAULT 0,
  item_sku text, model_sku text, item_name text,
  quantity int DEFAULT 1,               -- model_quantity_purchased
  unit_price numeric(12,2),             -- model_discounted_price
  original_price numeric(12,2),         -- model_original_price
  PRIMARY KEY (order_sn, item_id, model_id))

shopee_ads_diario (
  data date PRIMARY KEY, expense numeric(14,2) NOT NULL,
  clicks integer, impression bigint, broad_gmv numeric(14,2),
  atualizado_em timestamptz DEFAULT now())

shopee_difal (
  id text PRIMARY KEY,                  -- transaction_id OU md5(create_time|amount|reason) fallback
  transaction_id bigint, create_time timestamptz, create_date date,
  amount numeric(14,2),                 -- negativo (MONEY_OUT)
  order_sn text, reason text, atualizado_em timestamptz)
```

### B4.1 Decisões de modelagem (funcionou / refeito)
- **Refeito — `selling_price` híbrido:** originalmente só `COMPLETED` entrava e a bruta vinha do escrow (`cost_of_goods_sold`). Depois passou a ingerir **todos os status**; para não-COMPLETED (sem escrow ainda) a bruta vem de `Σ(unit_price × quantity)` dos itens; COMPLETED fica `selling_price NULL` para o escrow preencher. O fill usa COALESCE em cascata: `escrow COGS → soma itens → 0`.
- **Refeito — marcador de pendência de escrow:** mudou de `selling_price IS NULL` para **`escrow_adjusted IS NULL`** (pega também pedidos em trânsito).
- **Funcionou:** DIFAL com PK `id = transaction_id` e fallback `md5(create_time|amount|reason)` quando o id está ausente (dedup robusto).
- **Funcionou:** compartilhar `ml_custo_produto` entre canais (SKU unificado) — um único de-para de custos serve ML, Shopee, TikTok.

---

## B5. ERROS E LIÇÕES (Shopee)

1. **Vazão do escrow — o bug financeiro grave.** `get_escrow_detail` é **1 pedido/chamada**. O cron chamava a captura **uma vez/dia** (ex.: `fill_escrow(200)`), mas o intake real era ~192 pedidos/dia → folga de só +8/dia. Quando um **re-list em massa** semeou ~1.300 pendentes de uma vez, o ritmo diário levaria **~150 dias** para drenar. Resultado: um mês ficou **54% sem escrow e o card mostrou falso −R$189k** (o dado existia na API desde a venda, só não tinha sido capturado). Após backfill, o real era **−R$7.919**.
   - **FIX:** transformar a captura de escrow em **loop chunked**: `fill_escrow(100)` repetido até `remaining=0`, com **máx ~12 iterações (~1.200/dia)** e guarda de **480s**. Chunk de 100 evita timeout HTTP (uma chamada gigante não daria volume). Condições de saída: `remaining=0` **ou** `processed=0` (evita loop infinito) **ou** 12 iters **ou** 480s. Vazão ~6× o intake — um pico de 1.300 drena em ≤2 dias.

2. **`statement_timeout` subido para 900s.** Com o loop de escrow podendo ir a 480s + as outras fases, o teto antigo de 600s mataria o cron no meio — "gerando exatamente o backlog que este fix evita". `SET statement_timeout='900s'` no comando do job.

3. **`clock_timestamp()` vs `now()`.** A assinatura HMAC usa o timestamp; em loops longos `now()` (congelado na transação) faz a `sign` **expirar no meio do loop** → erros de assinatura intermitentes. Use `clock_timestamp()`.

4. **Idempotência.** `ON CONFLICT DO NOTHING` em pedidos/itens; `ON CONFLICT DO UPDATE` em ADS (por `data`) e DIFAL (por `id`).

5. **Provisório → definitivo (reconferência de escrow).** O `escrow_amount_after_adjustment` **muda** após a conclusão (reembolso/ajuste pós-venda). A reconferência semanal re-marca os COMPLETED recentes (~21 dias) zerando só `escrow_adjusted = NULL` para re-buscar o valor final. `net_commission`/frete permanecem (não somem do card). Auto-cicatrizante via o `WHERE` do fill.

6. **Reconferência de cancelados.** Varre `get_order_list` por `update_time` filtrando `CANCELLED`/`IN_CANCEL` em 30 dias (2 janelas de 15d) e "flipa" no Hub pedidos que ficaram cancelados na Shopee → saem da bruta/CMV.

7. **Lacuna repo↔banco (achado ao reconstruir).** Uma função de paginação (`shopee_ingest_pages`, wrapper que chama N vezes o `shopee_ingest_page` acumulando `listed/inserted/more/cursor`) **existia no banco mas não tinha migration no repo** (foi capturada via `pg_get_functiondef`). Ao reconstruir do zero, **crie esse wrapper de paginação** — não confie que toda função versionada está no repo; capture o estado real do banco.

### B5.1 Diferenças Shopee × Mercado Livre (resumo)
| Aspecto | Mercado Livre | Shopee |
|---|---|---|
| Assinatura | Bearer token simples | **HMAC-SHA256 por request** (2 base strings) |
| Access token | ~6h | ~4h |
| Refresh token | rotaciona (uso único) | rotaciona; janela ~30 dias |
| Paginação de pedidos | offset/limit (**teto 10k** → fatiar tempo) | **cursor** (`more`/`next_cursor`) |
| Repasse | via **billing** por `detail_sub_type`/`order_id` | via **escrow por pedido** (fonte de verdade) |
| Régua de status | **duas** (faturamento vs margem) | **uma** (não-cancelados) — deduções vêm desde a venda |
| DIFAL | `CDIFAL` no billing | `ADJUSTMENT_CENTER_DEDUCT` na **carteira** |
| Gargalo | billing trunca em silêncio / rate limit | **escrow 1 pedido/chamada** (vazão) |
| CMV | tabela `ml_custo_produto` (compartilhada) | mesma tabela, join com `unaccent` |

### B5.2 O que eu faria diferente (Shopee)
- Nascer com o **escrow em loop chunked** (nunca captura única/dia) e `statement_timeout` folgado — o backlog silencioso é o pior inimigo.
- Ancorar a M.C. no **repasse (escrow)** desde o dia 1 — não em "preço − taxas brutas".
- Já prever a **reconferência de escrow definitivo** (provisório muda).
- Versionar **toda** função (inclusive wrappers de paginação) capturando do banco.

---

# ═══════════════════════════════════════════════
# PARTE C — CHECKLIST DE CONSTRUÇÃO (do zero)
# ═══════════════════════════════════════════════

## C0. Pré-requisitos de plataforma (fazer ANTES de codar)
- **Mercado Livre:** criar aplicação no **DevCenter** (developers.mercadolivre.com.br). Anotar `client_id`/`client_secret`, cadastrar a **redirect URI** (ex.: `https://SEU_APP/api/auth/callback`), pedir os **scopes** `read`/`write`/`offline_access`. Ter uma conta de vendedor real para autorizar.
- **Shopee:** cadastro na **Shopee Open Platform / Partner Center**. Criar App, anotar `partner_id`/`partner_key`, cadastrar a **redirect URL** (callback), habilitar os módulos necessários (Order, Payment/Escrow, **Ads**, Wallet). **Whitelistar o IP de saída** (o IP do projeto Supabase). Autorizar a loja (gera `code`+`shop_id`).
- **Infra comum:** projeto Supabase (Postgres) com extensões `http`, `pg_cron`, `pgcrypto`/`hmac`, `vault` habilitadas. Um app Next.js com deploy contínuo. Uma tabela de **de-para de custos por SKU** (planilha do dono → `custo_produto`).

## C1. Ordem recomendada de implementação
Construa **um canal inteiro de ponta a ponta primeiro** (recomendo ML, que é o principal e mais complexo — resolvê-lo dá o molde para os outros), depois clone para a Shopee.

**Fase 0 — Fundações (uma vez):**
1. Camada `dataProvider` (`types.ts` / `mock.ts` / `supabase.ts` / `index.ts`) com flag de fonte; UI só consome o provider; regra de ouro `null` nunca zero. Pré-req: nada.
2. Padrão de tabelas: RLS on sem policy + RPCs `SECURITY DEFINER` + grants só `service_role`. Pré-req: entender por que SELECT direto não fura RLS.
3. Custódia OAuth genérica: Vault + tabela `*_oauth_state` singleton + Edge gateway `*-token` + advisory lock de refresh. Pré-req: extensões habilitadas.

**Fase 1 — Auth do canal:**
4. Rota de callback (`authorization_code`) que semeia o Vault. Pré-req: app criado no dev portal, redirect cadastrada.
5. Função `*_refresh_token` (rotação atômica, grava refresh novo primeiro, cache-hit por margem, `invalid_grant` → manual). Pré-req: seed feito.
6. (Shopee) helper de **assinatura HMAC** com as 2 base strings + `clock_timestamp()`. Pré-req: `hmac` habilitado.
7. Cron de keepalive de token (Shopee `*/3h`; ML opcional, criar INATIVO). Pré-req: `pg_cron`.

**Fase 2 — Bruta (faturamento):**
8. Tabelas `pedidos` + `itens` (PK natural). Ingestão "fechar ontem" idempotente (`ON CONFLICT`). Pré-req: token funcionando.
9. Paginação correta: ML **offset/limit + fatiar tempo sob teto 10k + passe de cancelados**; Shopee **cursor + janelas ≤15d + lotes de 50 no detail**. Pré-req: nº 8.
10. Régua de status (ML: duas réguas; Shopee: uma) + competência por data da venda em BRT + descartar dia corrente. Validar a **bruta** contra o relatório oficial do canal. Pré-req: nº 8.

**Fase 3 — Deduções (uma por vez, validando cada uma contra a fonte oficial):**
11. Comissão. ML: `sale_fee × quantidade` (cru, por unidade) — cuidado com rebate. Shopee: derivar do escrow. Pré-req: escrow (Shopee) / itens (ML).
12. Frete. ML: `/shipments/costs` por **pendentes da janela trailing** (posta com atraso). Shopee: embutido no escrow. Pré-req: envios (ML) / escrow (Shopee).
13. **Escrow (Shopee) — já como loop chunked** (nunca captura única). Pré-req: pedidos ingeridos.
14. ADS (dia fechado só; ML: product+brand+seguidores menos BPAD; Shopee: CPC diário). Pré-req: escopo Ads.
15. Full/Fulfillment (ML: `/full/details` por `creation_date`). Pré-req: billing.
16. Afiliados e DIFAL (ML: billing `CVAF`/`CDIFAL` por `creation_date`, ciclo 23→22, 2 faturas; Shopee: AMS no escrow / DIFAL na carteira). Pré-req: billing/wallet.
17. Custo Devoluções/Fricção (líquido: débitos − estornos). Pré-req: billing (ML) / escrow ajustado (Shopee).
18. CMV (`Σ custo × qtd` via de-para de SKU). Pré-req: tabela de custos populada + cobertura de SKU monitorada.

**Fase 4 — Robustez e automação (não deixar para depois):**
19. Orquestrador `pg_cron` diário por canal, com: **advisory lock de sessão**, `statement_timeout` folgado no comando, cada passo tolerante a falha (`begin/exception` → loga e segue, repesca no próximo run), **log honesto** (3 estados: `ok`/`verificado`/`completo`; nada hardcoded).
20. Reconferência (7d e 30d): relê e atualiza status/valores que mudaram; Shopee: re-marca escrow definitivo dos concluídos.
21. **Conferência de completude** onde a API trunca em silêncio (billing ML): contar no banco vs `total` da API e refazer o walk idempotente até bater.
22. Página de saúde/crons: semáforo vindo do `pg_cron` (não do log da app) + alerta com **N=2 dias** + cobertura de CMV.
23. Paridade repo↔banco: capturar toda função com `pg_get_functiondef` e versionar; varredura de segredos em todo commit.

**Fase 5 — Consolidação:**
24. DRE por canal + DRE consolidada (negócio inteiro) + gráfico diário com custos reais rateados. Dashboard abre no último mês fechado.
25. Conciliação contra o fechamento contábil oficial (tira o "preliminar" da margem).

## C2. Regras de ouro que valem para os dois canais (cole na parede)
1. Sem dado real = `null`, **nunca** zero inventado.
2. Todo segredo só no Vault/env; `refresh_token` rotaciona → gravar o novo **primeiro** e atômico.
3. Idempotência por chave natural em **tudo**; toda janela reprocessável.
4. Competência pela **data da venda** em BRT; timing de billing/frete reconcilia depois, não é erro.
5. Log **honesto** — distinga "falhou" de "não sei" de "está incompleto".
6. Todo cron: **lock + `statement_timeout` + tolerância a falha por passo**.
7. Desconfie de campos que parecem receita/custo: valide **cada dedução ao centavo** contra a fonte oficial antes de exibir.
8. **Ancore a margem no que efetivamente foi liquidado** (escrow/repasse), não em valores brutos.

---

*Fim do documento. Escrito a partir da análise do código-fonte (migrations, Edge Functions, camada de dados, histórico de commits) e da documentação técnica no Notion do projeto. Nenhuma credencial real incluída.*
