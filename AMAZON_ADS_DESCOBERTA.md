# Amazon Ads API — Fase 1 (custódia) + Descoberta (item 5/6)
*Sessão de 2026-07-30. Objetivo: eliminar o R$0 hardcoded do ADS Amazon no dashboard.*

## Estado da Fase 1 — FEITA e testada

Custódia no padrão ML/az, prefixo **`azads_`** (o `az_` é da SP-API — outra app LwA, outro refresh_token; não misturar):

- **Vault:** `azads_client_id`, `azads_client_secret`, `azads_token_key` semeados (verificado por length, 30/07). `azads_refresh_token` = placeholder `__SET_ME__` até a autorização.
- **Migration versionada** via Management API: `20260730120001_azads_oauth.sql` — tabela `azads_oauth_state` (singleton, com colunas `profile_id`/`country_code`/`currency_code` para a Fase 2), RPCs `azads_token_check`, `azads_get_state`, `azads_exchange_code`, `azads_refresh_token` (advisory lock 421982733, log em `oauth_refresh_log` conta `azads_brigide`).
- **Diferença deliberada vs ML:** a troca do authorization code roda **dentro do Postgres** (`azads_exchange_code`), padrão TikTok/Shopee — o client_secret nunca vai para env da Vercel. A rota `app/api/auth/callback-amazon-ads/route.ts` só repassa o `code` (troca imediata; falha ALTA com JSON 502 + motivo, e log no `oauth_refresh_log`). Exige `state=azads-hubfin`.
- **Edge Function `amazon-ads-token`** (deployada, `verify_jwt=false`, auth por `x-api-key` validada no Vault): único gateway de leitura; cache com folga de 10 min; refresh delegado ao RPC atômico. Smoke test 30/07: sem chave → 401; chave errada → 401; chave correta → **409 `refresh_token_not_seeded`** (correto: cadeia ainda não autorizada) com log honesto gravado.

### Como autorizar (ação do Luciano) — ATUALIZADO 03/08: plano B ativo

**03/08/2026:** a Vercel está pausada por **estouro de cota do plano free (3M/1M edge requests)** e só religa pagando upgrade — não vale a pena só para um callback. O **plano B virou o caminho principal**: callback como Edge Function **`amazon-ads-callback`** (padrão `tt-oauth-callback`, independe da Vercel), deployado e testado ponta a ponta em 03/08 (code falso atravessou até a Amazon e falhou alto com `invalid_request`). Migration `20260803120001_azads_exchange_redirect_param`: `azads_exchange_code` ganhou `p_redirect_uri` com allowlist das duas URLs; a rota da Vercel continua no repo como alternativa se a conta um dia voltar.

Passos:

1. Em [developer.amazon.com](https://developer.amazon.com) → **Login with Amazon** → security profile `amzn1.application.e5abd09d08fd447d9ada147e641a1e37` → **Web Settings** → **Edit** → adicionar em **Allowed Return URLs** (sem apagar a existente):

   ```
   https://klwczmapuupensozxbsr.supabase.co/functions/v1/amazon-ads-callback
   ```

2. Logado na conta que administra o Amazon Ads, abrir:

   ```
   https://www.amazon.com/ap/oa?client_id=amzn1.application-oa2-client.3ded0d38c5404a8fb3c24f33c761914a&scope=advertising%3A%3Acampaign_management&response_type=code&redirect_uri=https%3A%2F%2Fklwczmapuupensozxbsr.supabase.co%2Ffunctions%2Fv1%2Famazon-ads-callback&state=azads-hubfin
   ```

   Sucesso = JSON `"Amazon Ads autorizada..."` na tela; falha = JSON com o motivo (também em `oauth_refresh_log`).

*(Anomalia registrada de passagem: 3M de edge requests num app sem uso em produção sugere tráfego de bots na URL pública — pagar upgrade não resolveria isso.)*

## Item 5 — o que a API entrega de investimento (POR DOCUMENTAÇÃO; validar ao vivo na Fase 2)

> ⚠️ Nada abaixo foi verificado contra a API ao vivo — o token ainda não existe. São as respostas da documentação oficial e fontes secundárias, para validar assim que a autorização sair. **Nenhum número entra no DRE antes do item 6 bater.**

**Qual endpoint dá o gasto diário confiável:**
**Reports v3** (assíncrono): `POST /reporting/reports` em `advertising-api.amazon.com` (NA; perfil BR selecionado via header `Amazon-Advertising-API-Scope: {profileId}`). Um relatório por produto de anúncio: `reportTypeId` **`spCampaigns`** (Sponsored Products), **`sbCampaigns`** (Brands), **`sdCampaigns`** (Display), com `timeUnit: DAILY`, `groupBy: ["campaign"]` e colunas incluindo `date`, `campaignId`, `campaignName`, **`cost`** (gasto). Fluxo: criar relatório → poll do status → download (JSON gzip). O `GET /v2/profiles` (item 4) identifica o profileId BR e o `currencyCode`.

**Granularidade mínima e latência:**
Granularidade mínima = **dia** (`timeUnit: DAILY`); janela máxima por request ~31 dias (paginar por mês). Latência documentada: métricas disponíveis em **até 24h**, mas **flutuam por 48–72h** (remoção de cliques inválidos ajusta o `cost` para baixo). Régua prática a validar: dado do dia D só é considerado fechado em **D+3** — a reconferência (padrão `ml-ads-reconferir`) é obrigatória, não opcional.

**Janela de histórico (como no Mercado Ads?):**
Sim, existe e é pior em SB/SD: **Sponsored Products ~95 dias; Sponsored Brands e Display ~60 dias** de lookback via API. Consequência: julho/2026 (mês da explosão de pedidos) é alcançável hoje, mas **a janela anda** — ingestão não pode esperar meses. Confirmar os limites exatos ao vivo (tentar request além da janela e registrar o erro).

**Com ou sem impostos, e em que moeda:**
Moeda = a do perfil (`currencyCode` do profile BR; esperado **BRL** — confirmar no item 4). Impostos: o `cost` dos relatórios é o gasto de leilão **sem os impostos/taxas regulatórias que entram na fatura** (no Brasil a fatura destaca impostos por exigência legal; fontes de mercado reportam variância típica de **2–5%** entre relatório de campanha e fatura, por impostos/ajustes/câmbio). **Este é o ponto mais sensível para o DRE (Lucro Real)** — o item 6 mede exatamente isso, e a decisão relatório × fatura fica para depois dos números.

Fontes: docs oficiais ([overview de reporting](https://advertising.amazon.com/API/docs/en-us/guides/reporting/overview), [campaign reports v3](https://advertising.amazon.com/API/docs/en-us/guides/reporting/v3/report-types/campaign), [colunas v3](https://advertising.amazon.com/API/docs/en-us/guides/reporting/v3/columns), [impostos na fatura](https://advertising.amazon.com/library/guides/digital-ad-taxes)) + [Intentwise sobre retenção](https://www.intentwise.com/blog/amazon-advertising/explained-how-long-does-amazon-keep-your-ad-reports/), [Improvado sobre latência/variância](https://improvado.io/blog/amazon-ads-data-challenges), [m19 sobre billing](https://www.m19.com/blog/amazon-ads-billing). O site de docs da Amazon é JS-render (fetch direto vem vazio) — a validação fina será ao vivo contra a própria API.

## Item 6 — comparação API × painel (julho/2026)

**NÃO EXECUTADO — bloqueado pela autorização** (sem refresh_token não há chamada). Roteiro pronto para rodar na sequência:

1. `GET /v2/profiles` → profileId BR, `currencyCode`, `accountInfo` (gravar em `azads_oauth_state`).
2. Reports v3 `spCampaigns`+`sbCampaigns`+`sdCampaigns`, `timeUnit DAILY`, `groupBy campaign`, 01–31/07/2026; somar `cost`.
3. Luciano informa o total de julho que o painel do Amazon Ads mostra na tela (mesma janela, mesmo fuso — conferir o fuso do perfil no painel antes de comparar).
4. Reportar a diferença em % **por escrito neste documento** antes de qualquer ingestão. Só depois: cron, DRE, card.

## O que NÃO foi feito (por instrução)

Nenhum cron novo, nada gravado no DRE, card da Amazon intocado (o `ADS: 0` de `lib/data/supabase.ts` continua lá até o item 6 bater).
