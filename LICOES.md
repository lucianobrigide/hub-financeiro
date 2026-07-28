# LIÇÕES — Hub Financeiro (metodologia e achados)

> Extraído da página "Contexto para IA" do Notion (28/07/2026), que será arquivada.
> São **lições e achados**, não regras vivas do dia-a-dia (essas ficam no `CLAUDE.md`).
> **Números são referência do dia em que foram medidos — não verdade viva.**
> Regras vivas e "o que NÃO entra no billing ML": ver `CLAUDE.md`.

## Detectores de buraco de captura (os mais valiosos)
- **CMV / bruta ≈ 68%** é o melhor detector que existe: bate em ~68% em canais e meses diferentes, por caminhos de cálculo **independentes**. Se desviar, tem buraco de captura. (No TikTok deu ~79% e apontou um **fato de negócio** — preço —, não bug.)
- **"Dia com 0% de cancelamento" numa operação que cancela ~28% é sinal de alerta.** Quando um número parece limpo demais, geralmente está **incompleto**, não perfeito. → detector sugerido e **ainda não construído** (ver Pendências no CLAUDE.md).

## Metodologia
- **Ancorar no repasse real** (escrow / settlement / dinheiro que caiu). Reconstruir "preço − taxas brutas" é frágil: ignora subsídio de frete, reembolso de voucher e ajustes que a plataforma devolve.
- **Mas verificar, nunca assumir.** Auditoria completa (n=4): Shopee viés **−R$15,5k**, ML **~R$7k**, TikTok **0**, Amazon **0**. "Não tem viés" também é resultado — corrigir por analogia teria sido erro.
- **Achar um crédito é fácil; provar que ele ainda NÃO está contado é o trabalho.** 3 dos 4 maiores "créditos ignorados" do ML eram dupla contagem ou pass-through. **Nunca excluir/incluir por materialidade** — foi esse atalho que quase deixou passar os ~R$40k do CVVPRC.
- **"Cobertura 100%" é métrica cega.** 100% *dos pedidos que temos* não diz nada sobre pedidos nunca ingeridos — um denominador errado dá 100% de qualquer coisa. Completude exige denominador **externo** (a API, o export oficial, o `total` da fatura).

## Honestidade de log e robustez de cron
- **Os 3 estados da honestidade no log:** `ok=false` = não rodou (alerta real) · `verificado=false` = rodou mas não deu pra conferir = **"não sei"** (não alerta) · `completo=true/false` = verificado de verdade (alerta só se false). Confundir "não sei" com "falhou" gera cry-wolf; com "funcionou" gera falso ok.
- **Nunca logar `'ok'`/`sucesso=true` hardcoded** — o log tem que refletir o resultado real de cada passo (já houve caso de passo quebrado 4 dias com o log dizendo ok).
- **Classe de bug recorrente — "gatilho que nunca re-tenta".** Já apareceu **3×**: escrow (Shopee), billing (ML), finance (TikTok). Padrão: um flag é marcado, a fila busca os não-marcados, o registro sai da fila **pra sempre**. **Procurar ativamente na Amazon** (`az_settlement` incompleto tem o cheiro).

## Pegadinhas ainda só documentadas aqui
- ML billing **`/summary/details` é por CICLO** e não bate com a soma dos `/details` da mesma key. Para a régua do Hub (creation_date, mês-calendário), usar os `/details`.
- **TikTok:** endpoints rotulados "US/UK" **funcionam para o BR**; access token vai no header `x-tts-access-token` (não query).

## Plugs, resíduos e funções órfãs (armadilhas de manutenção)
- **`tt_deducoes.taxas` é um PLUG (resíduo), não uma soma explícita.** `taxas = fee_tax_total − comissão − afiliados − ads` — fecha a identidade por diferença. Efeito colateral: **qualquer campo novo que a TikTok adicionar ao `fin_fee_tax` cai dentro de `taxas` em silêncio**, sem virar linha própria. É comportamento versionado (mantido de propósito para reconciliar exato), mas se `taxas` crescer sem explicação, é aqui que olhar primeiro.
- **Funções órfãs `sp_comissao` / `sp_frete`.** Parecem a régua de dedução da Shopee, mas **não alimentam o app** — a M.C. viva da Shopee vem de `sp_repasse` (escrow real). Marcadas com `COMMENT ON FUNCTION` no próprio objeto (28/07/2026) para não enganar quem for ler. Lição: dedução calculada por RPC ≠ dedução exibida; confirmar o caminho vivo (grep no provider) antes de "consertar" uma leitora.
- **Cobertura ponderada por receita > cobertura por contagem.** No piso da M.C. (TikTok/Shopee), "17 de 96 pedidos" (17,7%) e "R$2.304 de R$13.601 liquidados" (16,9%) contam histórias parecidas aqui, mas divergem quando os pedidos grandes liquidam antes dos pequenos (ou vice-versa). O dinheiro é o denominador honesto.

## Nomenclatura resolvida
- **`CDLIT` = "Seguidores"** (o label da API é genérico: "Tarifa por campanha de publicidade"). Não existe uma linha de "Display Ads" faltando. Teste (jun/2026): `CDLIT` na fatura = **R$4.527,81** vs painel de Seguidores **R$4.569,29** (0,9%, mesmo corte de ciclo). Já captado em `ml_ads_diario` (produto `seguidores`); soma **dentro da linha ADS**.

## Achados de negócio (referência histórica)
- **Shopee, jun/2026:** margem de contribuição **negativa (−R$5.165,97)** — o ADS (~R$48k) afunda o canal.
- **TikTok — o problema é PREÇO, não taxa.** O `FIRENZE10` (carro-chefe, ~77% do CMV) é vendido lá ~25% mais barato que ML/Shopee, quase no custo; o `MARPAL9PRETOB` vende **abaixo do custo**. As taxas do TikTok são baratas — otimizar taxa não resolve. ⚠️ Verificar: promoção deliberada de entrada de canal ou desalinhamento de tabela?
- **Os fechamentos manuais da equipe são otimistas em 3 de 3 canais** — sempre na mesma direção. Este é o **argumento central do projeto**.
