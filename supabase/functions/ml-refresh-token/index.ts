// supabase/functions/ml-refresh-token/index.ts
//
// Renova o par de tokens OAuth do Mercado Livre (access + refresh).
//
// O refresh token do ML é de USO ÚNICO: cada refresh invalida o anterior.
// Por isso a operação inteira — ler -> chamar o ML -> gravar — roda dentro
// de UMA transação com `SELECT ... FOR UPDATE`, travando o registro para
// impedir que dois processos refresquem ao mesmo tempo e queimem o token.
//
// Segredos/variáveis usados (configurados no Supabase, nunca no frontend):
//   - ML_CLIENT_SECRET     -> segredo do app no Mercado Livre  (definir manualmente)
//   - SUPABASE_DB_URL      -> string de conexão Postgres        (auto-injetada)
//   - SUPABASE_SERVICE_ROLE_KEY -> disponível, mas o caminho com lock usa
//                                  conexão direta (ver nota no fim do arquivo).

import postgres from "npm:postgres@3.4.5";

const ML_TOKEN_URL = "https://api.mercadolibre.com/oauth/token";
const ML_CLIENT_ID = "7148019439656171";

// Se a linha foi atualizada há menos que isto, consideramos que um refresh
// concorrente "acabou de acontecer": devolvemos o access_token vigente em vez
// de rotacionar de novo (evita rotação dupla na corrida entre dois processos).
const CONCURRENT_REFRESH_WINDOW_MS = 10_000;

// Timeout da chamada externa ao ML, para não segurar o lock indefinidamente.
const ML_FETCH_TIMEOUT_MS = 10_000;

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Erro interno controlado — a mensagem NUNCA é enviada ao cliente. */
class RefreshError extends Error {}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  const clientSecret = Deno.env.get("ML_CLIENT_SECRET");
  const dbUrl = Deno.env.get("SUPABASE_DB_URL");

  // Falha de configuração não é uma falha de refresh: 500 genérico, sem vazar nada.
  if (!clientSecret || !dbUrl) {
    console.error("Configuração ausente: ML_CLIENT_SECRET ou SUPABASE_DB_URL");
    return jsonResponse(500, { error: "internal_error" });
  }

  // prepare:false p/ compatibilidade com o pooler em modo transação; max:1 pois
  // cada invocação da função é curta e usa uma única conexão.
  const sql = postgres(dbUrl, { prepare: false, idle_timeout: 5, max: 1 });

  try {
    const accessToken: string = await sql.begin(async (tx) => {
      // Nunca segura o lock/transação para sempre se algo travar.
      await tx`set local lock_timeout = '10s'`;
      await tx`set local statement_timeout = '20s'`;

      // (1) Lê e TRAVA o registro mais recente. Qualquer outro processo que
      //     chegar aqui fica bloqueado até esta transação commitar/abortar.
      const rows = await tx`
        select id, access_token, refresh_token, updated_at
        from ml_tokens
        order by created_at desc
        limit 1
        for update
      `;
      if (rows.length === 0) {
        throw new RefreshError("nenhum token cadastrado");
      }
      const row = rows[0];

      // Guarda de concorrência: se outro processo acabou de renovar (dentro da
      // janela), não rotaciona de novo — devolve o access_token já válido.
      const updatedAtMs = new Date(row.updated_at).getTime();
      if (Date.now() - updatedAtMs < CONCURRENT_REFRESH_WINDOW_MS) {
        return row.access_token as string;
      }

      // (2) POST ao Mercado Livre com o refresh_token atual (com timeout).
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), ML_FETCH_TIMEOUT_MS);
      let mlResp: Response;
      try {
        mlResp = await fetch(ML_TOKEN_URL, {
          method: "POST",
          headers: {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
          },
          body: new URLSearchParams({
            grant_type: "refresh_token",
            client_id: ML_CLIENT_ID,
            client_secret: clientSecret,
            refresh_token: row.refresh_token as string,
          }),
          signal: controller.signal,
        });
      } finally {
        clearTimeout(timer);
      }

      if (!mlResp.ok) {
        throw new RefreshError(`ML respondeu ${mlResp.status}`);
      }

      // (3) Novo par de tokens + validade.
      const data = await mlResp.json();
      const newAccess = data.access_token as string | undefined;
      const newRefresh = data.refresh_token as string | undefined;
      const expiresIn = data.expires_in as number | undefined;
      if (!newAccess || !newRefresh || !expiresIn) {
        throw new RefreshError("resposta do ML incompleta");
      }
      const expiresAt = new Date(Date.now() + expiresIn * 1000).toISOString();

      // (4) Substitui atomicamente, ainda sob o lock da transação.
      //     updated_at é atualizado pelo trigger ml_tokens_updated_at.
      await tx`
        update ml_tokens
        set access_token  = ${newAccess},
            refresh_token = ${newRefresh},
            expires_at    = ${expiresAt}
        where id = ${row.id}
      `;

      // (5) Devolve SOMENTE o access_token — refresh_token nunca sai daqui.
      return newAccess;
    });

    return jsonResponse(200, { access_token: accessToken });
  } catch (err) {
    // Qualquer falha de refresh -> 401 genérico, sem detalhes internos.
    // O detalhe real fica só no log do servidor.
    console.error("Falha no refresh do token ML:", err);
    return jsonResponse(401, { error: "unauthorized" });
  } finally {
    await sql.end({ timeout: 5 });
  }
});

// ---------------------------------------------------------------------------
// Nota de arquitetura: por que SUPABASE_DB_URL e não o service_role key?
//
// O requisito "travar o registro durante toda a operação (SELECT FOR UPDATE)"
// exige manter UMA transação aberta da leitura até a gravação, atravessando a
// chamada HTTP ao ML. O service_role key opera via PostgREST (supabase-js), que
// é stateless por request e não mantém transações nem locks entre chamadas.
// A conexão direta via SUPABASE_DB_URL (role `postgres`, que ignora RLS assim
// como o service_role) é o que permite o lock pedido. A função continua 100%
// server-side: o frontend nunca a acessa diretamente nem vê qualquer token.
// ---------------------------------------------------------------------------
