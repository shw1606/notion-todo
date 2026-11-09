#!/usr/bin/env node
// 구현 전 검증용: Views API에서 "me" 필터와 상대 날짜 필터가 어떻게 해석되는지 확인한다.
//
//   node scripts/probe-views.mjs login           # OAuth 로그인 → .probe/oauth-token.json
//   node scripts/probe-views.mjs setup           # 로그인 때 고른 페이지 아래 테스트 DB 생성
//   node scripts/probe-views.mjs run <DB URL|ID> # 토큰별로 뷰 정의·쿼리 결과 비교
//
// 설정은 .env.probe (커밋 안 함):
//   NOTION_OAUTH_CLIENT_ID, NOTION_OAUTH_CLIENT_SECRET   OAuth 테스트용
//   NOTION_INTERNAL_TOKEN                                  (선택) internal integration 비교용

import { createServer } from "node:http";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";

const NOTION_VERSION = "2026-03-11";
const PORT = 8787;
const REDIRECT_URI = `http://localhost:${PORT}/callback`;
const OUT = ".probe";
const TOKEN_FILE = `${OUT}/oauth-token.json`;

if (existsSync(".env.probe")) process.loadEnvFile(".env.probe");
mkdirSync(OUT, { recursive: true });

async function notion(token, method, path, body) {
  const res = await fetch(`https://api.notion.com/v1${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      "Notion-Version": NOTION_VERSION,
      "Content-Type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${json.code}: ${json.message}`);
  return json;
}

function login() {
  const { NOTION_OAUTH_CLIENT_ID: id, NOTION_OAUTH_CLIENT_SECRET: secret } = process.env;
  if (!id || !secret) throw new Error(".env.probe에 NOTION_OAUTH_CLIENT_ID / SECRET 필요");
  const state = randomBytes(16).toString("hex");
  const url = new URL("https://api.notion.com/v1/oauth/authorize");
  url.search = new URLSearchParams({
    client_id: id, redirect_uri: REDIRECT_URI, response_type: "code", owner: "user", state,
  });

  const server = createServer(async (req, res) => {
    const q = new URL(req.url, REDIRECT_URI).searchParams;
    if (!req.url.startsWith("/callback")) return res.writeHead(404).end();
    try {
      if (q.get("error")) throw new Error(`OAuth 거부: ${q.get("error")}`);
      if (q.get("state") !== state) throw new Error("state 불일치");
      const tokenRes = await fetch("https://api.notion.com/v1/oauth/token", {
        method: "POST",
        headers: {
          Authorization: `Basic ${Buffer.from(`${id}:${secret}`).toString("base64")}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ grant_type: "authorization_code", code: q.get("code"), redirect_uri: REDIRECT_URI }),
      });
      const token = await tokenRes.json();
      if (!tokenRes.ok) throw new Error(`토큰 교환 실패: ${JSON.stringify(token)}`);
      writeFileSync(TOKEN_FILE, JSON.stringify(token, null, 2));
      const owner = token.owner?.user;
      console.log(`로그인 완료. owner: ${owner?.name} (${owner?.id}), bot_id: ${token.bot_id}`);
      console.log(`access token 만료 필드: ${token.expires_in ?? "(없음)"}, refresh_token: ${token.refresh_token ? "있음" : "없음"}`);
      res.end("완료. 터미널로 돌아가세요.");
    } catch (e) {
      console.error(e.message);
      res.end(e.message);
    }
    server.close();
  });
  server.listen(PORT, "127.0.0.1", () => {
    console.log(`브라우저에서 Notion 로그인 진행:\n${url}`);
    execFile("open", [url.toString()]);
  });
}

function titleOf(page) {
  const prop = Object.values(page.properties ?? {}).find((p) => p.type === "title");
  return prop?.title.map((t) => t.plain_text).join("") || "(제목 없음)";
}

async function probe(label, token, databaseId) {
  console.log(`\n===== ${label} =====`);
  const me = await notion(token, "GET", "/users/me");
  console.log(`users/me: type=${me.type}, name=${me.name}, id=${me.id}` +
    (me.bot?.owner?.user ? `, bot owner user=${me.bot.owner.user.name} (${me.bot.owner.user.id})` : ""));

  const list = await notion(token, "GET", `/views?database_id=${databaseId}`);
  const dump = { me, views: [] };
  for (const ref of list.results) {
    const view = await notion(token, "GET", `/views/${ref.id}`);
    const query = await notion(token, "POST", `/views/${ref.id}/queries`, {});
    dump.views.push({ view, query });
    console.log(`\n[${view.type}] ${view.name}`);
    console.log(`  filter: ${JSON.stringify(view.filter)}`);
    console.log(`  sorts:  ${JSON.stringify(view.sorts)}`);
    console.log(`  quick_filters: ${JSON.stringify(view.quick_filters)}`);
    // 뷰 쿼리 결과에는 페이지 ID만 온다 → 제목은 페이지를 따로 조회해야 한다
    const names = [];
    for (const r of query.results) names.push(titleOf(await notion(token, "GET", `/pages/${r.id}`)));
    console.log(`  결과 ${query.total_count ?? query.results.length}건: ${names.join(", ") || "(없음)"}`);
  }
  const file = `${OUT}/${label}-${new Date().toISOString().slice(0, 10)}.json`;
  writeFileSync(file, JSON.stringify(dump, null, 2));
  console.log(`\n원본 응답 저장: ${file}`);
}

// 로그인 때 고른 페이지 아래에 테스트 DB와 항목 A·B·C를 만든다. 뷰는 사용자가 Notion UI로 만든다.
async function setup() {
  const token = JSON.parse(readFileSync(TOKEN_FILE));
  const at = token.access_token;
  const me = token.owner.user.id;
  const search = await notion(at, "POST", "/search", { filter: { property: "object", value: "page" } });
  const parent = search.results.find((p) => p.parent?.type === "workspace") ?? search.results[0];
  if (!parent) throw new Error("접근 가능한 페이지 없음 — 로그인 때 빈 페이지를 선택했는지 확인");

  const db = await notion(at, "POST", "/databases", {
    parent: { type: "page_id", page_id: parent.id },
    title: [{ text: { content: "probe-views 테스트" } }],
    initial_data_source: {
      properties: {
        이름: { title: {} },
        담당자: { people: {} },
        기한: { date: {} },
        완료: { checkbox: {} },
      },
    },
  });
  const dataSourceId = db.data_sources[0].id;
  const day = (offset) => {
    const d = new Date();
    d.setDate(d.getDate() + offset);
    return d.toLocaleDateString("sv-SE");
  };
  const rows = [
    ["A (나, 오늘)", [me], day(0)],
    ["B (담당자 없음, 오늘)", [], day(0)],
    ["C (나, 내일)", [me], day(1)],
  ];
  for (const [name, people, date] of rows) {
    await notion(at, "POST", "/pages", {
      parent: { type: "data_source_id", data_source_id: dataSourceId },
      properties: {
        이름: { title: [{ text: { content: name } }] },
        담당자: { people: people.map((id) => ({ id })) },
        기한: { date: { start: date } },
      },
    });
  }
  console.log(`테스트 DB 생성: ${db.url}\n부모 페이지: ${parent.url}`);
}

async function run(dbArg) {
  const databaseId = dbArg?.match(/[0-9a-f]{32}|[0-9a-f-]{36}/i)?.[0];
  if (!databaseId) throw new Error("DB URL 또는 ID를 넘겨주세요");
  console.log(`DB ${databaseId}, 오늘 날짜(로컬): ${new Date().toLocaleDateString("sv-SE")}`);
  if (existsSync(TOKEN_FILE)) await probe("oauth", JSON.parse(readFileSync(TOKEN_FILE)).access_token, databaseId);
  else console.log("OAuth 토큰 없음 — 먼저 login 실행");
  if (process.env.NOTION_INTERNAL_TOKEN) await probe("internal", process.env.NOTION_INTERNAL_TOKEN, databaseId);
}

const [cmd, arg] = process.argv.slice(2);
const main = { login, setup, run: () => run(arg) }[cmd];
if (!main) {
  console.log("사용법: node scripts/probe-views.mjs login | setup | run <DB URL|ID>");
  process.exit(1);
}
Promise.resolve(main()).catch((e) => { console.error(e.message); process.exit(1); });
