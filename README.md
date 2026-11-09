# notion-todo

Notion 데이터베이스를 단일 진실 소스로 쓰는 오픈소스 투두 앱. **iPhone · iPad · Mac** 세 플랫폼에서
동작하고, 세 플랫폼 모두 홈화면/데스크톱 위젯에서 바로 체크할 수 있다.

> **EN:** An open-source todo app backed by your own Notion database, with native SwiftUI +
> WidgetKit apps and interactive widgets on iPhone, iPad and Mac. No property mapping:
> each widget shows one of your existing Notion views, using its saved filter and sort.
> Sign in with Notion (OAuth) — a tiny stateless token-exchange function holds the client
> secret; your data never touches it. The app and widgets talk to Notion directly. An
> optional self-hosted relay (Notion webhook → APNs widget push) comes later for
> near-instant widget refresh. Scaffold stage — no implementation yet.

**상태:** 스캐폴드 (2026-11-08). 구현 코드 없음.

---

## 왜 만드나

기존 서드파티 앱(Widget for Notion, WFN, Nutshell 등)은 iPhone 중심이고, Mac에서는 iPad 앱을
그대로 돌리거나 Mac 전용 앱이 따로 있다. 실제로 Mac에서 써본 결과 바로 동작하지 않았다.
**세 플랫폼을 하나의 네이티브 코드베이스로, 오픈소스로** 제공하는 앱이 목표다.

## 목표

1. 자기 Notion DB의 투두 항목을 iPhone·iPad·Mac에서 읽고, 완료 토글까지 양방향 반영
2. 세 플랫폼 모두 **인터랙티브 위젯** — 위젯에서 바로 체크 (AppIntent)
3. **설정 거의 없음** — 속성 매핑을 받지 않는다. 위젯은 사용자가 Notion에 이미 만든 **뷰**를
   그대로 보여준다 (아래 "뷰 기반 위젯" 참고)
4. **Notion으로 로그인** (OAuth) — 토큰 복사·DB 공유 같은 개발자 절차 없음
5. 데이터 서버 없음 — 앱·위젯이 Notion과 직접 통신한다
6. 변경이 수 분 내 반영 (아래 제약 3번 참고 — "실시간"은 위젯에서 성립하지 않는다)

## 뷰 기반 위젯

사용자는 Notion에 "오늘", "내 작업" 같은 뷰를 이미 만들어 두고 필터·정렬을 걸어 둔다.
그 뷰가 곧 "위젯에 뭘 보여줄지"에 대한 답이다. Views API(`/v1/views`)로 뷰를 그대로 조회한다.

| 필요한 것 | 결정 방법 | 사용자 입력 |
|---|---|---|
| 표시 항목·순서 | 뷰에 저장된 `filter`·`quick_filters`·`sorts`로 data source 쿼리 (제약 9번) | 위젯 편집에서 뷰 선택 |
| 제목 | DB의 title 속성 (항상 정확히 하나) | 없음 |
| 완료 토글 대상 | 뷰 필터가 참조하는 status/checkbox 속성 | 없음 |
| 기한 | 뷰 정렬·필터에 쓰인 date 속성, 없으면 유일한 date 속성 | 없음 |
| 보조 표시 속성 | 뷰에서 보이게 설정된 속성 | 없음 |

- **완료의 정의는 뷰 필터가 가진다.** `Status ≠ Complete 그룹` 또는 `Done 체크 안 됨` 필터가 걸려
  있으면, 위젯 체크 시 그 속성을 바꾼다. Status는 Complete 그룹의 첫 옵션으로(그룹은 To-do /
  In progress / Complete로 고정), checkbox는 true로. 그러면 항목이 뷰 조건에서 빠져 위젯에서도
  사라진다 — Notion에서 체크한 것과 같은 동작.
- **뷰 선택은 위젯 설정(AppIntent 설정형 위젯)으로 받는다.** 위젯마다 다른 뷰를 고를 수 있다.
  첫 추가 시 기본값은 접근 가능한 첫 DB의 첫 뷰.
- 뷰 필터에서 완료 속성을 추론할 수 없으면(필터 없음 등) title 외 status → checkbox 순으로
  DB에 하나뿐인 속성을 쓰고, 그래도 모호하면 읽기 전용으로 표시한다.
- "작업 데이터베이스로 지정"(Turn into Tasks) 여부는 API에 노출되지 않으므로 쓰지 않는다.

## 플랫폼

| 플랫폼 | 앱 | 위젯 | 비고 |
|---|---|---|---|
| iPhone | SwiftUI | 홈화면·잠금화면 | |
| iPad | SwiftUI (같은 iOS 타깃) | 홈화면 | 큰 위젯 크기 대응 |
| Mac | SwiftUI **네이티브 macOS 타깃** | 데스크톱·알림센터 | "Designed for iPad" 실행이 아니라 macOS용으로 빌드 |

위젯 인터랙션(AppIntent 버튼·토글) 때문에 최소 iOS/iPadOS 17, macOS 14가 하한이다.
실제 최소 버전은 열린 결정 참고.

## 아키텍처

### 1단계 — 데이터 서버 없음 (현재 계획)

```
                    ┌───────────────────────────────┐
  로그인·토큰 갱신 시만 │ 토큰 교환 함수 (서버리스, 무상태)   │── client secret 보관
                    └──────────────┬────────────────┘
                                   │ code → access/refresh token
Notion API                         ▼
   ▲  뷰 조회 / 완료 토글 (사용자 OAuth 토큰, App Group 공유 Keychain)
   │
   ├── iOS/iPadOS 앱 + 위젯 (SwiftUI + WidgetKit, AppIntent 토글)
   └── macOS 앱 + 위젯      (같은 코드, 멀티플랫폼 타깃)
```

- 앱을 열면 Notion을 직접 조회 → 즉시 반영
- 위젯 체크 토글은 AppIntent에서 Notion API를 직접 호출
- 위젯 타임라인 갱신 시 Notion을 직접 조회 → 다른 곳에서 바꾼 내용은 15~60분 내 반영
- 레이트리밋은 사용자 토큰별로 분리된다

### 토큰 교환 함수 — 왜 필요한가

Notion OAuth는 인가 코드를 토큰으로 바꿀 때와 토큰을 갱신할 때 모두 `client_id:client_secret`
HTTP Basic 인증을 요구한다. PKCE 같은 비밀 없는 네이티브 앱용 흐름은 문서에 없다.
client secret을 앱 번들에 넣으면 누구나 추출해 이 앱을 사칭할 수 있으므로, secret을 가진 작은 함수가
교환·갱신 두 요청만 대신 보낸다.

- **하는 일:** `POST /v1/oauth/token` 프록시 2종(코드 교환, 토큰 갱신) + OAuth 리다이렉트 페이지
- **안 하는 일:** 토큰·사용자 데이터 저장, Notion 데이터 조회. 무상태이며 로그를 남기지 않는다
- **호출 빈도:** 로그인 1회 + 토큰 갱신 시. 사용자당 하루 수 회 이하
- **비용:** 서버리스 무료 티어 범위 (예: Cloudflare Workers 무료 10만 req/일). 사실상 0원
- **직접 빌드하는 사용자:** 자기 Notion public integration + 자기 함수 배포, 또는 internal integration
  토큰을 직접 입력하는 대체 경로를 쓴다

### 2단계 — 셀프호스팅 중계 서버 (선택)

위젯 반영 지연(15~60분)을 줄이고 싶은 사용자를 위한 선택 기능. 서버 없이도 앱은 완전히 동작한다.

```
Notion DB
   │  webhook: data_source.content_updated  (Notion-Version 2025-09-03)
   ▼
중계 서버 (얇음: webhook 수신 → APNs 푸시 발송)
   │  APNs 푸시
   ├──────────────► iPhone / iPad 위젯 리로드
   └──────────────► Mac 위젯 리로드
```

서버가 꼭 필요한 이유는 하나다. webhook은 공개 HTTPS 엔드포인트로만 받을 수 있고, APNs 푸시도
서버에서만 보낼 수 있다. 데이터 조회·토글은 1단계처럼 클라이언트가 Notion과 직접 주고받는다.
APNs 인증 키는 앱 번들 ID·팀에 묶이므로, 직접 빌드한 사용자는 자기 팀의 키로 서버를 띄워야 한다.

### 계획 디렉터리 구조

```
apps/          Xcode 프로젝트 — iOS(iPhone·iPad)·macOS 앱 + 위젯 확장, 공유 코드
  Shared/        Notion 클라이언트(Views API), 모델, 뷰 해석(완료·기한 추론), Keychain
  App/           SwiftUI 앱
  Widgets/       WidgetKit 확장 + AppIntent (뷰 선택 설정, 완료 토글)
  Config/        xcconfig (팀 ID·번들 ID 접두사는 Local.xcconfig로 분리, 커밋 안 함)
auth/          OAuth 토큰 교환 함수 (서버리스, 무상태)
server/        (2단계) Notion webhook 수신 + APNs 발송 (Node)
docs/          설계·결정 기록
```

## 제약 — 설계에 반드시 반영할 것

1. **빌드에는 macOS + Xcode가 필요하다.** Linux CI에서는 빌드·서명할 수 없다.
2. **Apple 서명:** 무료 개발자 계정은 7일마다 재서명·재설치가 필요하다. 직접 빌드해서 상시
   쓰려면 Apple Developer Program(연 $99)이 사실상 전제다. 일반 사용자는 배포 채널(열린 결정)로 받는다.
3. **위젯은 실시간이 아니다.** WidgetKit 타임라인 갱신은 OS 예산 제약을 받는다
   (실측 15~60분 간격). 즉시 반영 경로는 APNs 푸시로 위젯을 리로드하는 방법뿐이고,
   푸시를 보내려면 서버가 필요하다 (2단계).
   → 동기화의 현실적 정의: **앱 내부는 즉시, 위젯은 수 분~수십 분.**
4. **Notion 레이트리밋** 평균 3 req/s (인티그레이션 단위). 사용자별 토큰이므로 1인 사용량으로는
   여유가 크다. 단, 위젯 타임라인 하나당 쿼리 1회로 묶고 페이지 단위 반복 조회는 피한다.
5. **Notion 접근 권한.** 앱은 OAuth 로그인 때 사용자가 고른 페이지·DB에만 접근한다. 할 일 DB가
   빠졌으면 앱에서 "페이지 추가 선택"으로 OAuth를 다시 띄운다.
6. **토큰 보관.** access/refresh 토큰은 App Group 공유 Keychain에만 저장한다. 소스 코드·번들·로그·
   분석 도구로 내보내지 않는다. 앱은 서드파티 분석/트래킹 SDK를 넣지 않는다.
7. **뷰 해석 실패 처리.** 뷰가 삭제되거나 필터 속성이 바뀌면 위젯에 명확한 오류와 "뷰 다시 선택"
   안내를 띄운다. 완료 속성을 추론할 수 없으면 읽기 전용으로 표시한다.
8. **Views API 버전.** Views API는 `Notion-Version` 2025-09-03 이상이 필요하다(문서 예시는
   2026-03-11). 뷰 쿼리는 저장된 필터·정렬 위에 추가 필터를 얹을 수 없고, 결과 캐시는 약 15분 유지된다.
9. **검증 결과 (2026-11-09, `scripts/probe-views.mjs`):**
   - Notion UI에서 건 필터는 뷰의 `filter`가 아니라 **`quick_filters`**에 저장된다. 둘 다 읽어 AND로 합친다.
   - `"me"`는 OAuth 토큰에서 **로그인 사용자로 해석된다** ✅ (`people.contains: "me"`로 저장)
   - "오늘"은 고정 날짜가 아니라 **`date.equals: "today"`로 저장되고** 오늘 항목이 맞게 걸린다 ✅.
     날짜가 바뀐 뒤 재계산되는지는 2026-11-10 재확인 예정
   - 뷰 쿼리(`/views/{id}/queries`) 결과에는 **페이지 ID만** 온다 → 제목을 보려면 페이지마다 추가 요청.
   - data source 쿼리도 `"me"`·`"today"`를 그대로 받고 같은 결과를 낸다 → 위젯은 **뷰 정의를 읽어
     `filter`+`quick_filters`+`sorts`로 data source 쿼리 1회**를 보내 속성까지 한 번에 받는다

## 직접 빌드하기 (구현 후 채움)

1. `apps/Config/Local.xcconfig.example`을 `Local.xcconfig`로 복사하고 자기 팀 ID·번들 ID 접두사 입력
2. Notion 로그인: 자기 public integration의 client ID와 `auth/` 함수 URL을 `Local.xcconfig`에 입력,
   또는 internal integration 토큰을 앱에서 직접 입력하는 대체 경로 사용
3. Xcode에서 iOS 또는 macOS 스킴 빌드

## 사용 흐름

1. Notion으로 로그인 → 할 일 DB가 있는 페이지 선택
2. 위젯 추가 → (원하면) 위젯 편집에서 Notion 뷰 선택
3. 끝 — 속성 지정 없음

## 설정

앱은 OAuth 로그인으로 토큰을 받아 Keychain에 저장한다. 사용자 설정 파일·환경 변수가 없다.

`auth/` 토큰 교환 함수는 배포 환경의 시크릿으로 설정한다.

| 변수 | 설명 |
|---|---|
| `NOTION_OAUTH_CLIENT_ID` | Notion public integration client ID |
| `NOTION_OAUTH_CLIENT_SECRET` | Notion public integration client secret (함수에만 존재) |
| `NOTION_OAUTH_REDIRECT_URI` | Notion에 등록한 리다이렉트 URI (함수의 콜백 페이지) |

2단계 중계 서버는 `.env`로 설정한다 (`.env`는 커밋하지 않는다).

| 변수 | 설명 |
|---|---|
| `NOTION_API_KEY` | Notion 인티그레이션 토큰 |
| `NOTION_DATA_SOURCE_ID` | 투두 소스 data source ID |
| `NOTION_WEBHOOK_SECRET` | `X-Notion-Signature` HMAC 검증용 |
| `CLIENT_API_KEY` | 클라이언트 → 중계 서버 인증 키 (푸시 토큰 등록용) |

## 열린 결정

- [x] 클라이언트: 네이티브 SwiftUI + WidgetKit (2026-11-08)
- [x] 오픈소스, iPhone·iPad·Mac 지원 (2026-11-08)
- [ ] 최소 OS 버전 — iOS/iPadOS 17·macOS 14(인터랙티브 위젯 하한) vs 더 최신
- [ ] 배포 채널 — App Store / TestFlight 공개 베타 / 소스 빌드만
- [x] 속성 매핑 없이 Notion 뷰 기반 위젯 + OAuth 로그인 (2026-11-08)
- [ ] 토큰 교환 함수 호스팅 — Cloudflare Workers / Vercel Functions 등
- [ ] 위젯 체크 토글을 첫 릴리스에 포함할지, 읽기 전용으로 시작할지
- [ ] 2단계 중계 서버 도입 여부

## 기여

아직 스캐폴드 단계다. 설계 논의는 이슈로, 결정은 [docs/DECISIONS.md](docs/DECISIONS.md)에 기록한다.
PR에 Notion 토큰·팀 ID·`Local.xcconfig`가 섞이지 않게 주의한다.

## 참고

- [Notion Webhooks](https://developers.notion.com/reference/webhooks)
- [Event types & delivery](https://developers.notion.com/reference/webhooks-events-delivery)
- [2025-09-03 업그레이드 가이드](https://developers.notion.com/docs/upgrade-guide-2025-09-03)
- [Working with views](https://developers.notion.com/guides/data-apis/working-with-views)
- [Authorization (OAuth)](https://developers.notion.com/docs/authorization)
- [Status 속성 그룹](https://developers.notion.com/reference/update-property-schema-object)

## 라이선스

MIT — [LICENSE](LICENSE)
