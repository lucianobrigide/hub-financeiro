# scripts/ingest — Ingestão de pedidos do Mercado Livre

Scripts de ingestão (Módulo 02) que populam as tabelas `ml_pedidos`,
`ml_pedido_itens` e `ml_devolucoes` no Supabase a partir da API do Mercado Livre.

> ⚠️ **Etapa de backfill manual** — ainda não há cron. Rodar sob demanda.
> Só a **bruta** é validada; cancelado/devolvido seguem como pendência.

## Credenciais (lidas de env/arquivo, nunca hardcoded)

| Variável | Para quê | Origem |
| --- | --- | --- |
| `ML_TOKEN_URL` | endpoint da Edge Function `ml-token` | env |
| `ML_TOKEN_API_KEY` | `x-api-key` do `ml-token` | env |
| `SUPABASE_ACCESS_TOKEN` | PAT do Supabase (escrita via Management API) | env, **fallback** `~/.claude.json` (`mcpServers.supabase.env`) |

O **access token do ML** é obtido em runtime via `ml-token` (nunca impresso). A
escrita no Supabase usa a **Management API** (`/v1/projects/<ref>/database/query`)
com o PAT — porque não há `service_role` local nos scripts.

Exemplo de execução:

```bash
export ML_TOKEN_URL='https://<ref>.supabase.co/functions/v1/ml-token'
export ML_TOKEN_API_KEY='<ml_token_key>'      # NÃO commitar
# SUPABASE_ACCESS_TOKEN: do env ou lido do ~/.claude.json automaticamente

node scripts/ingest/ingest_param.mjs 2026-06-12
```

## Scripts

| Script | O que faz | Como rodar |
| --- | --- | --- |
| `backfill_junho.mjs` | Backfill 01–25/06/2026, um dia por vez, UPSERT idempotente, sem passe de claims. Log de progresso por dia. | `node scripts/ingest/backfill_junho.mjs` |
| `ingest_param.mjs` | Ingere **um** dia (argumento `YYYY-MM-DD`), só bruta/itens + `data_cancelamento`. | `node scripts/ingest/ingest_param.mjs 2026-06-12` |
| `ingest_dia.mjs` | Reprocessa um dia (hardcoded 10/06) incluindo o passe de claims/devoluções (que ainda retorna HTTP 400 — ver doc técnica no Notion). | `node scripts/ingest/ingest_dia.mjs` |

## Regras (resumo)

- `data` = `date_closed` convertido para **America/Sao_Paulo** (SP = UTC−3).
- Janela por dia via `order.date_closed.from/.to`; filtro de precisão no código
  descarta os pedidos que "vazam" para a 1ª hora do dia seguinte.
- **Bruta** = Σ `valor_total` por `date_closed` (SP), excluindo só `status = 'invalid'`.
- UPSERT por `pedido_id` → reprocessar não duplica.
- Rate limit: sequencial, `limit=50`, backoff + jitter no 429.

A documentação técnica completa (schema, mapeamento, resultado do backfill,
pendências) está no Notion: **🏦 Hub Financeiro › Módulo 02 — Doc Técnica: Ingestão ML**.
