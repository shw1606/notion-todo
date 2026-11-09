# auth/ — Notion OAuth 토큰 교환 함수

"Notion으로 로그인"에 필요한 아주 작은 서버리스 함수. Notion OAuth는 코드 교환과 토큰 갱신에
client secret을 요구하는데, secret을 앱에 넣으면 누구나 꺼내 쓸 수 있다. 그래서 secret은 이 함수에만 둔다.

| 경로 | 하는 일 |
|---|---|
| `GET /callback` | Notion 리다이렉트 URI. 앱(`ASWebAuthenticationSession`)이 이 주소로의 이동을 가로챈다 |
| `POST /token` | `{code, state, code_verifier}` → PKCE 확인 → Notion에 코드 교환 |
| `POST /refresh` | `{refresh_token}` → Notion에 토큰 갱신 (갱신 토큰은 매번 바뀌고, 이전 접근 토큰은 즉시 무효) |
| `GET /.well-known/apple-app-site-association` | HTTPS 로그인 콜백용 `webcredentials` 연결 |

**저장하지 않는다.** 토큰·사용자 데이터·요청 본문 어디에도 남기지 않는다. Notion 데이터를 조회하지도 않는다.
호출은 로그인할 때와 토큰 갱신할 때뿐이라 Cloudflare Workers 무료 티어(하루 10만 요청) 안에서 충분하다.

## 배포 (Cloudflare Workers)

1. **Notion public integration 만들기** — [개발자 포털](https://app.notion.com/developers/connections)에서
   OAuth 연결을 만들고 리다이렉트 URI에 `https://notion-todo-auth.<서브도메인>.workers.dev/callback`을 넣는다.
   필요한 권한: 콘텐츠 읽기·수정·추가, 사용자 정보(이메일 제외 가능).
2. **설정** — `wrangler.toml`의 `NOTION_OAUTH_REDIRECT_URI`(1번과 같은 값)와 `APPLE_APP_IDS`
   (`<팀 ID>.<앱 번들 ID>`, 예: `ABCDE12345.com.example.notiontodo`)를 채운다.
3. **비밀값** — 로그인 후 client ID·secret을 넣는다.
   ```sh
   cd auth
   npx wrangler login
   npx wrangler secret put NOTION_OAUTH_CLIENT_ID
   npx wrangler secret put NOTION_OAUTH_CLIENT_SECRET
   ```
4. **배포** — `npx wrangler deploy`
5. **앱 연결** — `apps/Config/Local.xcconfig`에:
   ```
   NT_OAUTH_CLIENT_ID = <client ID>
   NT_AUTH_BASE_URL = https:/$()/notion-todo-auth.<서브도메인>.workers.dev
   NT_AUTH_HOST = notion-todo-auth.<서브도메인>.workers.dev
   ```
   (xcconfig에서 `//`는 주석이라 `https:/$()/`로 쓴다.)

자기 도메인을 쓰려면 Workers 사용자 지정 도메인을 붙이고 1·2·5번의 주소를 그 도메인으로 바꾼다.

## 테스트

```sh
cd auth && npm test     # Node 22.18+ (TypeScript 그대로 실행), 의존성 설치 불필요
```

Notion에 실제로 붙지 않고, Notion 응답을 흉내 내 PKCE 검증·요청 형태·오류 처리를 확인한다.
앱 쪽 PKCE(`TodoCore/AuthSession.swift`)와 같은 RFC 7636 예시 값으로 서로 맞는지도 검사한다.
