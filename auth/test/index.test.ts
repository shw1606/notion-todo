import assert from "node:assert/strict";
import { test } from "node:test";
import { challengeFor, handle, type Env } from "../src/index.ts";

const env: Env = {
  NOTION_OAUTH_CLIENT_ID: "client-id",
  NOTION_OAUTH_CLIENT_SECRET: "client-secret",
  NOTION_OAUTH_REDIRECT_URI: "https://auth.example.com/callback",
};

const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

type Call = { url: string; init: RequestInit };

function upstreamReturning(status: number, body: unknown) {
  const calls: Call[] = [];
  const fn = async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return new Response(JSON.stringify(body), { status });
  };
  return { fn, calls };
}

function post(path: string, body: unknown, contentType = "application/json") {
  return new Request(`https://auth.example.com${path}`, {
    method: "POST",
    headers: { "Content-Type": contentType },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

test("PKCE challenge matches RFC 7636 appendix B (same as the app)", async () => {
  assert.equal(await challengeFor(verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
});

test("token exchange forwards to Notion with Basic auth when PKCE matches", async () => {
  const { fn, calls } = upstreamReturning(200, { access_token: "a", refresh_token: "r", bot_id: "b" });
  const state = `nonce1234.${await challengeFor(verifier)}`;
  const response = await handle(post("/token", { code: "c", state, code_verifier: verifier }), env, fn);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { access_token: "a", refresh_token: "r", bot_id: "b" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.notion.com/v1/oauth/token");
  const headers = new Headers(calls[0].init.headers);
  assert.equal(headers.get("Authorization"), `Basic ${btoa("client-id:client-secret")}`);
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
    grant_type: "authorization_code",
    code: "c",
    redirect_uri: "https://auth.example.com/callback",
  });
  assert.equal(response.headers.get("Cache-Control"), "no-store");
});

test("token exchange rejects a wrong verifier without calling Notion", async () => {
  const { fn, calls } = upstreamReturning(200, {});
  const state = `nonce1234.${await challengeFor(verifier)}`;
  const other = "A".repeat(43);
  const response = await handle(post("/token", { code: "c", state, code_verifier: other }), env, fn);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "invalid_pkce" });
  assert.equal(calls.length, 0);
});

test("token exchange rejects malformed state and verifier", async () => {
  const { fn, calls } = upstreamReturning(200, {});
  let response = await handle(post("/token", { code: "c", state: "no-dot", code_verifier: verifier }), env, fn);
  assert.deepEqual(await response.json(), { error: "invalid_state" });
  const state = `nonce1234.${await challengeFor(verifier)}`;
  response = await handle(post("/token", { code: "c", state, code_verifier: "short" }), env, fn);
  assert.deepEqual(await response.json(), { error: "invalid_verifier" });
  response = await handle(post("/token", { state, code_verifier: verifier }), env, fn);
  assert.deepEqual(await response.json(), { error: "invalid_code" });
  assert.equal(calls.length, 0);
});

test("Notion errors pass through with their status", async () => {
  const { fn } = upstreamReturning(400, { error: "invalid_grant" });
  const state = `nonce1234.${await challengeFor(verifier)}`;
  const response = await handle(post("/token", { code: "used", state, code_verifier: verifier }), env, fn);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: "invalid_grant" });
});

test("refresh forwards the refresh token", async () => {
  const { fn, calls } = upstreamReturning(200, { access_token: "a2", refresh_token: "r2" });
  const response = await handle(post("/refresh", { refresh_token: "r1" }), env, fn);
  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(String(calls[0].init.body)), { grant_type: "refresh_token", refresh_token: "r1" });
});

test("rejects wrong methods, content types, bad JSON and large bodies", async () => {
  const { fn, calls } = upstreamReturning(200, {});
  assert.equal((await handle(new Request("https://auth.example.com/token"), env, fn)).status, 405);
  assert.equal((await handle(post("/refresh", "refresh_token=r", "application/x-www-form-urlencoded"), env, fn)).status, 415);
  assert.equal((await handle(post("/refresh", "{not json"), env, fn)).status, 400);
  assert.equal((await handle(post("/refresh", { refresh_token: "x".repeat(5000) }), env, fn)).status, 413);
  assert.equal((await handle(new Request("https://auth.example.com/elsewhere"), env, fn)).status, 404);
  assert.equal(calls.length, 0);
});

test("missing secrets is a server error, not a forwarded request", async () => {
  const { fn, calls } = upstreamReturning(200, {});
  const response = await handle(post("/refresh", { refresh_token: "r" }), { ...env, NOTION_OAUTH_CLIENT_SECRET: "" }, fn);
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: "not_configured" });
  assert.equal(calls.length, 0);
});

function get(path: string) {
  return new Request(`https://auth.example.com${path}`);
}

test("callback hands code and state to the app scheme", async () => {
  const { fn, calls } = upstreamReturning(200, {});
  const response = await handle(get("/callback?code=c&state=nonce1234.abc&extra=x"), env, fn);
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), "notiontodo://oauth?code=c&state=nonce1234.abc");
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.match(await response.text(), /href="notiontodo:\/\/oauth\?code=c&amp;state=nonce1234\.abc"/);
  assert.equal(calls.length, 0);
});

test("callback forwards a denial, honors a custom app URL, and shows a page when opened directly", async () => {
  const { fn } = upstreamReturning(200, {});
  const denied = await handle(get("/callback?error=access_denied&state=s"), env, fn);
  assert.equal(denied.headers.get("Location"), "notiontodo://oauth?state=s&error=access_denied");
  const fork = await handle(get("/callback?code=c&state=s"), { ...env, APP_CALLBACK_URL: "myfork://oauth" }, fn);
  assert.equal(fork.headers.get("Location"), "myfork://oauth?code=c&state=s");
  const page = await handle(get("/callback"), env, fn);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get("Location"), null);
  assert.match(await page.text(), /Return to the app/);
  assert.equal((await handle(get("/.well-known/apple-app-site-association"), env, fn)).status, 404);
});
