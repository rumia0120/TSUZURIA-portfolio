import assert from "node:assert/strict";
import test from "node:test";
import { handleTurnEmails } from "../functions/turn-emails/index.ts";

const secret = "test-scheduler-secret-for-unit-test";
const environment = {
  TURN_EMAIL_CRON_SECRET: secret,
  SUPABASE_URL: "https://database.example.invalid",
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_fixture" }),
  RESEND_API_KEY: "test-resend-key",
  TURN_EMAIL_FROM: "notices@example.invalid",
  TURN_EMAIL_APP_URL: "https://tsuzuria.example.invalid",
};

function invoke(fetcher, overrides = {}, authorization = `Bearer ${secret}`, method = "POST") {
  const request = new Request("https://database.example.invalid/functions/v1/turn-emails", {
    method,
    headers: { Authorization: authorization },
  });
  const env = { ...environment, ...overrides };
  return handleTurnEmails(request, (name) => env[name], fetcher);
}

function fakeTransport(replies, { finish = true, claimError = false } = {}) {
  const calls = [];
  const jobs = replies.map((_, i) => ({
    job_id: `74000000-0000-0000-0000-00000000000${i + 1}`,
    lease_token: `75000000-0000-0000-0000-00000000000${i + 1}`,
    email: `member${i + 1}@example.invalid`,
  }));
  let nextReply = 0;

  async function fetcher(input, options) {
    const url = new URL(input);
    calls.push({ url, body: JSON.parse(options.body), headers: new Headers(options.headers), signal: options.signal });
    if (url.pathname === "/rest/v1/rpc/claim_turn_email_jobs") {
      return claimError ? Response.json({ error: "private detail" }, { status: 500 }) : Response.json(jobs);
    }
    if (url.pathname === "/rest/v1/rpc/finish_turn_email_job") return Response.json(finish);
    if (url.href === "https://api.resend.com/emails") {
      const reply = replies[nextReply++];
      if (reply instanceof Error) throw reply;
      return reply;
    }
    throw new Error("Unexpected request during test");
  }

  return { fetcher, calls, jobs };
}

test("only the configured scheduler can claim jobs", async () => {
  const { fetcher, calls } = fakeTransport([]);
  assert.equal((await invoke(fetcher, {}, "Bearer wrong-secret")).status, 401);
  assert.equal((await invoke(fetcher, { TURN_EMAIL_CRON_SECRET: "short" })).status, 503);
  assert.equal((await invoke(fetcher, {}, `Bearer ${secret}`, "GET")).status, 405);
  assert.equal((await invoke(fetcher, { TURN_EMAIL_APP_URL: "https://tsuzuria.example.invalid/#invite=private" })).status, 503);
  assert.deepEqual(calls, []);
});

test("uses the job UUID for idempotency and sends only generic text and the app link", async () => {
  const { fetcher, calls, jobs } = fakeTransport([Response.json({ id: "provider-id" })]);
  const response = await invoke(fetcher);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { claimed: 1, accepted: 1, retryable: 0, failed: 0, unconfirmed: 0 });

  const [claim, send, finish] = calls;
  assert.deepEqual(claim.body, { batch_size: 4 });
  assert.equal(claim.headers.get("apikey"), "sb_secret_fixture");
  assert.equal(claim.headers.get("Authorization"), null);
  assert.equal(send.headers.get("Idempotency-Key"), `turn-email/${jobs[0].job_id}`);
  assert.deepEqual(send.body, {
    from: "notices@example.invalid",
    to: [jobs[0].email],
    subject: "TSUZURIAであなたの番です",
    text: "交換日記を書く番になりました。\n\nTSUZURIAを開く\nhttps://tsuzuria.example.invalid/",
  });
  assert.deepEqual(finish.body, {
    job_id: jobs[0].job_id, lease_token: jobs[0].lease_token, delivered: true, retryable: false,
  });
  assert.ok(calls.every(({ signal }) => signal instanceof AbortSignal));
});

test("retries transient statuses including concurrent idempotency, with the same key on a later attempt", async () => {
  const statuses = [
    new Response(null, { status: 429 }),
    new Response(null, { status: 503 }),
    Response.json({ name: "concurrent_idempotent_requests" }, { status: 409 }),
    new Error("timeout simulation"),
  ];
  const initial = fakeTransport(statuses);
  const response = await invoke(initial.fetcher);
  assert.deepEqual(await response.json(), { claimed: 4, accepted: 0, retryable: 4, failed: 0, unconfirmed: 0 });
  const finished = initial.calls.filter(({ url }) => url.pathname.endsWith("/finish_turn_email_job"));
  assert.equal(finished.length, 4);
  assert.ok(finished.every(({ body }) => !body.delivered && body.retryable));

  const retry = fakeTransport([new Response(null, { status: 204 })]);
  assert.equal((await invoke(retry.fetcher)).status, 200);
  assert.equal(retry.calls[1].headers.get("Idempotency-Key"), initial.calls[1].headers.get("Idempotency-Key"));
});

test("a payload conflict and a validation error are terminal", async () => {
  const { fetcher, calls } = fakeTransport([
    Response.json({ name: "invalid_idempotent_request" }, { status: 409 }),
    new Response(null, { status: 422 }),
  ]);
  const response = await invoke(fetcher);
  assert.deepEqual(await response.json(), { claimed: 2, accepted: 0, retryable: 0, failed: 2, unconfirmed: 0 });
  const finished = calls.filter(({ url }) => url.pathname.endsWith("/finish_turn_email_job"));
  assert.ok(finished.every(({ body }) => !body.delivered && !body.retryable));
});

test("a failed claim performs no delivery and an unconfirmed update reports only counts", async () => {
  const failed = fakeTransport([], { claimError: true });
  const claimResponse = await invoke(failed.fetcher);
  assert.equal(claimResponse.status, 503);
  assert.deepEqual(await claimResponse.json(), { error: "Could not claim jobs" });
  assert.equal(failed.calls.length, 1);

  const unconfirmed = fakeTransport([new Response(null, { status: 204 })], { finish: false });
  const finishResponse = await invoke(unconfirmed.fetcher);
  assert.equal(finishResponse.status, 503);
  assert.deepEqual(await finishResponse.json(), { claimed: 1, accepted: 0, retryable: 0, failed: 0, unconfirmed: 1 });
});
