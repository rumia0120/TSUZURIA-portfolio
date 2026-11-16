import { createHash, timingSafeEqual } from "node:crypto";

const batchSize = 4;
const databaseTimeout = 4_000;
const resendTimeout = 5_000;

type ReadEnv = (name: string) => string | undefined;
type Job = { job_id: string; lease_token: string; email: string };
type ResendConfig = { apiKey: string; from: string; appUrl: string };
type SendResult = "accepted" | "retryable" | "failed";

function hasValidAuthorization(request: Request, secret: string) {
  const authorization = request.headers.get("authorization");
  if (!authorization) return false;
  const supplied = createHash("sha256").update(authorization).digest();
  const expected = createHash("sha256").update(`Bearer ${secret}`).digest();
  return timingSafeEqual(supplied, expected);
}

function readAppUrl(value: string | undefined) {
  if (!value) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) return null;
    return url.href;
  } catch {
    return null;
  }
}

function readDatabaseHeaders(readEnv: ReadEnv) {
  const secretKeys = readEnv("SUPABASE_SECRET_KEYS");
  const secretKey = secretKeys && JSON.parse(secretKeys)?.default;
  const headers = new Headers({ "Content-Type": "application/json" });
  if (typeof secretKey === "string" && secretKey.startsWith("sb_secret_")) {
    headers.set("apikey", secretKey);
    return headers;
  }

  const serviceRoleKey = readEnv("SUPABASE_SERVICE_ROLE_KEY");
  if (!serviceRoleKey) return null;
  headers.set("apikey", serviceRoleKey);
  headers.set("Authorization", `Bearer ${serviceRoleKey}`);
  return headers;
}

async function sendTurnEmail(
  job: Job, { apiKey, from, appUrl }: ResendConfig, fetcher: typeof fetch,
): Promise<SendResult> {
  try {
    const response = await fetcher("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "Idempotency-Key": `turn-email/${job.job_id}`,
      },
      body: JSON.stringify({
        from,
        to: [job.email],
        subject: "TSUZURIAであなたの番です",
        text: `交換日記を書く番になりました。\n\nTSUZURIAを開く\n${appUrl}`,
      }),
      cache: "no-store",
      redirect: "error",
      signal: AbortSignal.timeout(resendTimeout),
    });

    if (response.status === 409) {
      const conflict: { name?: string } | null = await response.json().catch(() => null);
      // Resend can still be processing this key. A changed payload must not be sent with a new key.
      return conflict?.name === "concurrent_idempotent_requests" ? "retryable" : "failed";
    }
    void response.body?.cancel().catch(() => {});
    if (response.ok) return "accepted";
    return response.status === 429 || response.status >= 500 ? "retryable" : "failed";
  } catch {
    // The provider may already have accepted a timed-out request. Keep the same idempotency key.
    return "retryable";
  }
}

function reply(body: object, status = 200) {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store", ...(status === 405 ? { Allow: "POST" } : {}) },
  });
}

export async function handleTurnEmails(request: Request, readEnv: ReadEnv, fetcher = fetch) {
  if (request.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const cronSecret = readEnv("TURN_EMAIL_CRON_SECRET");
  if (!cronSecret || cronSecret.length < 32) return reply({ error: "Worker unavailable" }, 503);
  if (!hasValidAuthorization(request, cronSecret)) return reply({ error: "Unauthorized" }, 401);

  try {
    const supabaseUrl = readEnv("SUPABASE_URL");
    const databaseHeaders = readDatabaseHeaders(readEnv);
    const apiKey = readEnv("RESEND_API_KEY");
    const from = readEnv("TURN_EMAIL_FROM");
    const appUrl = readAppUrl(readEnv("TURN_EMAIL_APP_URL"));
    if (!supabaseUrl || !databaseHeaders || !apiKey || !from || !appUrl) {
      return reply({ error: "Worker unavailable" }, 503);
    }

    const rpc = async (name: string, parameters: object) => {
      try {
        const response = await fetcher(new URL(`/rest/v1/rpc/${name}`, supabaseUrl), {
          method: "POST",
          headers: databaseHeaders,
          body: JSON.stringify(parameters),
          cache: "no-store",
          redirect: "error",
          signal: AbortSignal.timeout(databaseTimeout),
        });
        if (response.ok) return await response.json();
        void response.body?.cancel().catch(() => {});
      } catch {
        // A failed result update leaves the lease available for recovery.
      }
      return null;
    };

    const jobs: Job[] = await rpc("claim_turn_email_jobs", { batch_size: batchSize });
    if (!Array.isArray(jobs) || jobs.length > batchSize) return reply({ error: "Could not claim jobs" }, 503);

    const totals = { claimed: jobs.length, accepted: 0, retryable: 0, failed: 0, unconfirmed: 0 };
    for (const job of jobs) {
      const result = await sendTurnEmail(job, { apiKey, from, appUrl }, fetcher);
      const finished = await rpc("finish_turn_email_job", {
        job_id: job.job_id,
        lease_token: job.lease_token,
        delivered: result === "accepted",
        retryable: result === "retryable",
      });

      if (finished === true) totals[result] += 1;
      else totals.unconfirmed += 1;
    }

    return reply(totals, totals.unconfirmed > 0 ? 503 : 200);
  } catch {
    return reply({ error: "Worker unavailable" }, 503);
  }
}

// Declare only the Deno APIs this entrypoint uses so the repository's Node typecheck can include it.
declare const Deno: {
  env: { get: ReadEnv };
  serve: (handler: (request: Request) => Promise<Response>) => unknown;
};

if (typeof Deno !== "undefined") {
  Deno.serve((request) => handleTurnEmails(request, (name) => Deno.env.get(name)));
}
