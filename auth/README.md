# auth/ — Notion OAuth 토큰 교환 함수

"Notion으로 로그인"에 필요한 아주 작은 서버리스 함수. Notion OAuth는 코드 교환과 토큰 갱신에
client secret을 요구하는데, secret을 앱에 넣으면 누구나 꺼내 쓸 수 있다. 그래서 secret은 이 함수에만 둔다.

| 경로 | 하는 일 |
|---|---|
| `GET /callback` | Notion 리다이렉트 URI. 받은 `code`·`state`(거절이면 `error`)를 앱 주소 `notiontodo://oauth`로 넘긴다(302) |
| `POST /token` | `{code, state, code_verifier}` → PKCE 확인 → Notion에 코드 교환 |
| `POST /refresh` | `{refresh_token}` → Notion에 토큰 갱신 (갱신 토큰은 매번 바뀌고, 이전 접근 토큰은 즉시 무효) |

앱 주소로 넘기므로 도메인 연결(Associated Domains·AASA)이 필요 없다. 앱의 인증 창(`ASWebAuthenticationSession`)이
그 이동을 가로채고, Mac에서 기본 브라우저 탭으로 연 경우에는 브라우저가 앱을 연다. 다른 앱이 같은 주소로 `code`를
받아도 `code_verifier`는 연결을 시작한 앱에만 있어서 교환할 수 없다.

**저장하지 않는다.** 토큰·사용자 데이터·요청 본문 어디에도 남기지 않는다. Notion 데이터를 조회하지도 않는다.
호출은 로그인할 때와 토큰 갱신할 때뿐이라 무료 플랜으로 충분하다.

같은 코드(`src/index.ts`의 `handle`)가 Vercel과 Cloudflare Workers 양쪽에서 돈다.
공식 빌드는 Vercel의 `https://notion-todo-auth.vercel.app`을 쓴다.

## 배포

1. **Notion public integration 만들기** — [개발자 포털](https://app.notion.com/developers/connections)에서
   "신규 연결" → 인증 방법 **OAuth**, 설치 가능 워크스페이스 **모든 워크스페이스**로 만들고 리다이렉트 URI에
   `<함수 주소>/callback`을 넣는다. 설치 범위는 만든 뒤에 바꿀 수 없다 — 내 워크스페이스로 만들면 다른 사람은 연결하지 못한다.
   권한은 콘텐츠 읽기·업데이트·삽입, 사용자 정보는 "이메일 주소를 제외한 사용자 정보 읽기"로 한다 — 앱은 이메일을
   쓰지 않고, 이메일까지 고르면 동의 화면에 "사용자와 이메일 보기"가 붙는다.
   이름은 `Todo Widget for Notion`, 아이콘은 앱 아이콘(`apps/NotionTodo/Assets.xcassets/AppIcon.appiconset/mac-512.png`)으로
   한다 — 사용자가 연결할 때 Notion 동의 화면에 그대로 보인다.
2. **함수 배포** — 아래 Vercel 또는 Cloudflare Workers.
3. **앱 연결** — `apps/Config/Local.xcconfig`에:
   ```
   NT_OAUTH_CLIENT_ID = <client ID>
   NT_AUTH_BASE_URL = https:/$()/notion-todo-auth.vercel.app
   ```
   (xcconfig에서 `//`는 주석이라 `https:/$()/`로 쓴다.)
4. **확인** — `curl -i "<함수 주소>/callback?code=x&state=y"`가 `302`와 `Location: notiontodo://oauth?code=x&state=y`를 돌려준다.

### Vercel

```sh
cd auth
vercel link --project notion-todo-auth
vercel env add NOTION_OAUTH_CLIENT_ID production
vercel env add NOTION_OAUTH_CLIENT_SECRET production --sensitive
vercel env add NOTION_OAUTH_REDIRECT_URI production   # https://<프로젝트>.vercel.app/callback
vercel deploy --prod
```

`api/index.ts`가 `handle`을 감싸고, `vercel.json`의 `routes`가 모든 경로를 그 함수로 보낸다. `rewrites`로 바꾸지 말 것 —
정적 출력이 없는 프로젝트는 Vercel이 올린 소스를 정적 파일로도 내보내는데, `rewrites`는 정적 파일 다음에 적용된다.
`.vercelignore`는 허용 목록이라 `.dev.vars` 같은 비밀 파일은 올라가지 않는다. 환경 변수를 바꾸면 다시 배포해야 반영된다.

### Cloudflare Workers

1. `wrangler.toml`의 `NOTION_OAUTH_REDIRECT_URI`를 `https://notion-todo-auth.<서브도메인>.workers.dev/callback`으로 채운다.
2. 비밀값을 넣고 배포한다.
   ```sh
   cd auth
   npx wrangler login
   npx wrangler secret put NOTION_OAUTH_CLIENT_ID
   npx wrangler secret put NOTION_OAUTH_CLIENT_SECRET
   npx wrangler deploy
   ```

자기 도메인을 쓰려면 Vercel 도메인이나 Workers 사용자 지정 도메인을 붙이고, Notion 리다이렉트 URI·
`NOTION_OAUTH_REDIRECT_URI`·`NT_AUTH_BASE_URL`을 그 도메인으로 바꾼다.

## 로컬에서 해 보기

배포하지 않고 이 맥에서 "Notion 연결하기"를 끝까지 시험할 수 있다.

1. Notion integration의 리다이렉트 URI에 `http://localhost:8787/callback`을 더한다.
2. `auth/.dev.vars`(커밋 안 함)에 비밀값을 둔다.
   ```
   NOTION_OAUTH_CLIENT_ID=<client ID>
   NOTION_OAUTH_CLIENT_SECRET=<client secret>
   NOTION_OAUTH_REDIRECT_URI=http://localhost:8787/callback
   ```
3. `npm run dev` (포트 8787).
4. `apps/Config/Local.xcconfig`에 `NT_AUTH_BASE_URL = http:/$()/localhost:8787`과 client ID를 넣고 앱을 빌드한다.
   개발 빌드를 `NT_DEV_SIGNED_OUT=1`로 실행하면 Keychain의 로그인을 건드리지 않고 온보딩부터 시작한다.

## 테스트

```sh
cd auth && npm test     # Node 22.18+ (TypeScript 그대로 실행), 의존성 설치 불필요
```

Notion에 실제로 붙지 않고, Notion 응답을 흉내 내 PKCE 검증·요청 형태·오류 처리를 확인한다.
앱 쪽 PKCE(`TodoCore/AuthSession.swift`)와 같은 RFC 7636 예시 값으로 서로 맞는지도 검사한다.
