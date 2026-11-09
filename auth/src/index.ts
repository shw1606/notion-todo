// Notion OAuth 토큰 교환 함수 (PLAN 5.4).
//
// 하는 일: client secret을 들고 Notion에 코드 교환·토큰 갱신을 대신 요청한다.
// 안 하는 일: 토큰·사용자 데이터 저장, Notion 데이터 조회, 요청 본문 로그. 무상태다.
//
// Notion OAuth엔 PKCE가 없어서 앱↔함수 사이에서 직접 한다: 앱이 state = "<nonce>.<challenge>"로 인가를 시작하고,
// 교환할 때 code_verifier를 보내면 SHA-256(verifier)가 challenge와 같은지 확인한다.
// 리다이렉트를 가로챈 쪽은 code·state만 알고 verifier는 모르므로 교환할 수 없다.

export interface Env {
  NOTION_OAUTH_CLIENT_ID: string;
  NOTION_OAUTH_CLIENT_SECRET: string;
  /** Notion에 등록한 리다이렉트 URI = 이 함수의 /callback 주소 */
  NOTION_OAUTH_REDIRECT_URI: string;
  /** 로그인 결과를 넘길 앱 주소. 앱의 URL 스킴을 바꾼 경우에만 쓴다 (기본 notiontodo://oauth) */
  APP_CALLBACK_URL?: string;
}

type Upstream = (input: string, init: RequestInit) => Promise<Response>;

const NOTION_TOKEN_URL = "https://api.notion.com/v1/oauth/token";
const APP_CALLBACK_URL = "notiontodo://oauth";
const MAX_BODY_BYTES = 4096;
const VERIFIER = /^[A-Za-z0-9\-._~]{43,128}$/;
const STATE = /^([A-Za-z0-9\-_]{8,128})\.([A-Za-z0-9\-_]{43})$/;

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, (input, init) => fetch(input, init));
  },
};

export async function handle(request: Request, env: Env, upstream: Upstream): Promise<Response> {
  const { pathname } = new URL(request.url);
  try {
    switch (pathname) {
      case "/callback":
        return request.method === "GET" ? callback(request, env) : methodNotAllowed();
      case "/token":
        return request.method === "POST" ? await exchange(request, env, upstream) : methodNotAllowed();
      case "/refresh":
        return request.method === "POST" ? await refresh(request, env, upstream) : methodNotAllowed();
      default:
        return json({ error: "not_found" }, 404);
    }
  } catch (error) {
    if (error instanceof HttpError) return json({ error: error.code }, error.status);
    return json({ error: "server_error" }, 500);
  }
}

// MARK: - 경로

async function exchange(request: Request, env: Env, upstream: Upstream): Promise<Response> {
  const body = await readJSON(request);
  const code = stringField(body, "code");
  const state = stringField(body, "state");
  const verifier = stringField(body, "code_verifier");
  const match = STATE.exec(state);
  if (!match) throw new HttpError(400, "invalid_state");
  if (!VERIFIER.test(verifier)) throw new HttpError(400, "invalid_verifier");
  if ((await challengeFor(verifier)) !== match[2]) throw new HttpError(400, "invalid_pkce");
  return forward(env, upstream, {
    grant_type: "authorization_code",
    code,
    redirect_uri: env.NOTION_OAUTH_REDIRECT_URI,
  });
}

async function refresh(request: Request, env: Env, upstream: Upstream): Promise<Response> {
  const body = await readJSON(request);
  return forward(env, upstream, { grant_type: "refresh_token", refresh_token: stringField(body, "refresh_token") });
}

/** Notion 응답을 그대로 돌려준다(상태 코드 포함). secret은 이 요청에만 쓰인다. */
async function forward(env: Env, upstream: Upstream, payload: Record<string, string>): Promise<Response> {
  if (!env.NOTION_OAUTH_CLIENT_ID || !env.NOTION_OAUTH_CLIENT_SECRET) throw new HttpError(500, "not_configured");
  const response = await upstream(NOTION_TOKEN_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${env.NOTION_OAUTH_CLIENT_ID}:${env.NOTION_OAUTH_CLIENT_SECRET}`)}`,
      "Content-Type": "application/json",
      "Notion-Version": "2026-03-11",
    },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  return new Response(text, {
    status: response.status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

/**
 * Notion이 돌아오는 곳. 받은 code·state(거절했으면 error)를 앱 스킴으로 그대로 넘기면
 * 앱의 ASWebAuthenticationSession이 그 이동을 가로챈다 — Associated Domains 없이 된다.
 * 다른 앱이 같은 스킴으로 code를 받아도 verifier가 없어서 교환하지 못한다.
 */
function callback(request: Request, env: Env): Response {
  const query = new URL(request.url).searchParams;
  const forwarded = new URLSearchParams();
  for (const key of ["code", "state", "error"]) {
    const value = query.get(key);
    if (value) forwarded.set(key, value);
  }
  if (!forwarded.has("code") && !forwarded.has("error")) return callbackPage();
  return callbackPage(`${env.APP_CALLBACK_URL || APP_CALLBACK_URL}?${forwarded}`);
}

/** 앱으로 넘길 주소가 있으면 그리로 보낸다(302). 본문은 브라우저로 직접 열렸을 때만 보인다. */
function callbackPage(location?: string): Response {
  const link = location ? `<p><a href="${escapeHTML(location)}">Open Notion Todo · 앱 열기</a></p>` : "";
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Notion Todo</title><body style="font:17px -apple-system,system-ui;padding:2rem;max-width:32rem;margin:auto">
<h1>Notion Todo</h1><p>Return to the app to finish signing in. You can close this page.</p>
<p lang="ko">앱으로 돌아가 로그인을 마치세요. 이 페이지는 닫아도 됩니다.</p>${link}</body>`;
  const headers: Record<string, string> = { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" };
  if (location) Object.assign(headers, { Location: location, "Referrer-Policy": "no-referrer" });
  return new Response(html, { status: location ? 302 : 200, headers });
}

// MARK: - 도우미

export async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

function escapeHTML(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function readJSON(request: Request): Promise<Record<string, unknown>> {
  if (!(request.headers.get("Content-Type") ?? "").includes("application/json")) {
    throw new HttpError(415, "unsupported_media_type");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) throw new HttpError(413, "too_large");
  try {
    const value: unknown = JSON.parse(text);
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch {
    // 아래에서 처리
  }
  throw new HttpError(400, "invalid_json");
}

function stringField(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string" || value.length === 0 || value.length > 2048) {
    throw new HttpError(400, `invalid_${key}`);
  }
  return value;
}

function methodNotAllowed(): Response {
  return json({ error: "method_not_allowed" }, 405);
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

class HttpError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string) {
    super(code);
    this.status = status;
    this.code = code;
  }
}
