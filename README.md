# Todo Widget for Notion

Notion 데이터베이스를 단일 진실 소스로 쓰는 오픈소스 투두 앱 (저장소 이름 `notion-todo`). **iPhone · iPad · Mac** 세 플랫폼에서
동작하고, 세 플랫폼 모두 홈화면/데스크톱 위젯에서 바로 체크할 수 있다.

> **EN:** An open-source todo app backed by your own Notion database, with native SwiftUI +
> WidgetKit apps and interactive widgets on iPhone, iPad and Mac. No property mapping:
> each widget shows one of your existing Notion views, using its saved filter and sort.
> Sign in with Notion (OAuth) — a tiny stateless token-exchange function holds the client
> secret; your data never touches it. The app and widgets talk to Notion directly. An
> optional self-hosted relay (Notion webhook → APNs widget push) comes later for
> near-instant widget refresh. Implemented for iPhone, iPad and Mac (2026-11-09); release via
> TestFlight is pending — see docs/RELEASE.md.

**상태:** 구현 완료 (2026-11-09) — iPhone·iPad·Mac 앱과 위젯, 로그인 함수, 테스트, CI.
배포(TestFlight)와 실기기 확인은 계정이 필요한 단계라 [docs/RELEASE.md](docs/RELEASE.md)에 정리돼 있다.
디자인·구현 계획과 현황은 [docs/PLAN.md](docs/PLAN.md).

---

## 왜 만드나

**스티키 메모에 휘갈겨 쓰던 할 일을 Notion DB로 옮기고, 그걸 위젯으로 항상 띄워두기 위해서.**
그래서 담당자·기한·상태 같은 형식을 요구하지 않는다. 한 줄 적고, 끝나면 체크하면 된다.
형식을 갖춘 작업 DB도 그대로 쓸 수 있지만, 그건 선택이지 전제가 아니다.

기존 서드파티 앱(Widget for Notion, WFN, Nutshell 등)은 iPhone 중심이고, Mac에서는 iPad 앱을
그대로 돌리거나 Mac 전용 앱이 따로 있다. 실제로 Mac에서 써본 결과 바로 동작하지 않았다.
**세 플랫폼을 하나의 네이티브 코드베이스로, 오픈소스로** 제공하는 앱이 목표다.

## 기본 예시 DB — 📝 할 일 메모

처음 쓰는 사람에게 권하는 최소 구성. 앱 온보딩에서 이 구성으로 새 DB를 만들어 주는 옵션도 둔다.

| 속성 | 타입 | 입력 |
|---|---|---|
| 내용 | title | 직접 입력 — 이것만 쓰면 된다 |
| 완료 | checkbox | 위젯에서 체크 |
| 만든 시간 | created_time | 자동 (정렬용) |

| 뷰 | 필터 | 정렬 |
|---|---|---|
| **할 일** (첫 번째 뷰 = 위젯 기본값) | 완료 = 체크 안 됨 | 만든 시간 내림차순 |
| 완료함 | 완료 = 체크됨 | 만든 시간 내림차순 |

정렬은 `created_time` **속성**으로 건다. 뷰에 timestamp 정렬을 직접 넣으면 API가 받긴 하지만 저장하지 않는다.

## 목표

1. 자기 Notion DB의 투두 항목을 iPhone·iPad·Mac에서 읽고, 완료 토글까지 양방향 반영
2. 세 플랫폼 모두 **인터랙티브 위젯** — 위젯에서 바로 체크 (AppIntent)
3. **설정 거의 없음** — 속성 매핑을 받지 않는다. 위젯은 사용자가 Notion에 이미 만든 **뷰**를
   그대로 보여준다 (아래 "뷰 기반 위젯" 참고)
4. **Notion 연결하기 한 번** (OAuth) — 토큰 복사·DB 공유 같은 개발자 절차 없음. 페이지를 고르지 않아도
   메모 DB를 Notion "개인 페이지"에 만들어 주고, 쓰던 할 일 DB가 있으면 그것을 고를 수 있다
5. 데이터 서버 없음 — 앱·위젯이 Notion과 직접 통신한다
6. 변경이 수 분 내 반영 (아래 제약 3번 참고 — "실시간"은 위젯에서 성립하지 않는다)

## 뷰 기반 위젯

사용자는 Notion에 "오늘", "내 작업" 같은 뷰를 이미 만들어 두고 필터·정렬을 걸어 둔다.
그 뷰가 곧 "위젯에 뭘 보여줄지"에 대한 답이다. Views API(`/v1/views`)로 뷰를 그대로 조회한다.

| 필요한 것 | 결정 방법 | 사용자 입력 |
|---|---|---|
| 표시 항목·순서 | 뷰에 저장된 `filter`·`quick_filters`·`sorts`로 data source 쿼리 (제약 9번). 앱에서 줄을 끌어 정한 순서가 있으면 그 순서(기기에만 저장) | 위젯 편집에서 뷰 선택 |
| 제목 | DB의 title 속성 (항상 정확히 하나) | 없음 |
| 완료 토글 대상 | 뷰 필터가 참조하는 status/checkbox 속성 | 없음 |
| 기한 | 뷰 정렬·필터에 쓰인 date 속성, 없으면 유일한 date 속성 | 없음 |
| 보조 표시 속성 | 뷰에서 보이게 설정된 속성 | 없음 |

- **완료의 정의는 뷰 필터가 가진다.** `Status ≠ Complete 그룹` 또는 `Done 체크 안 됨` 필터가 걸려
  있으면, 위젯 체크 시 그 속성을 바꾼다. Status는 Complete 그룹의 첫 옵션으로(그룹은 To-do /
  In progress / Complete로 고정), checkbox는 true로. 그러면 항목이 뷰 조건에서 빠져 위젯에서도
  사라진다 — Notion에서 체크한 것과 같은 동작.
- **뷰 선택은 위젯 설정(AppIntent 설정형 위젯)으로 받는다.** 위젯마다 다른 뷰를 고를 수 있다.
  목록에는 앱에서 고른 DB의 뷰만 나온다.
  첫 추가 시 기본값은 앱에서 마지막으로 연 뷰, 없으면 **체크할 수 있고 아직 안 한 일을 보여주는 뷰**.
  API의 뷰 목록 순서는 Notion 탭 순서와 달라서 "첫 번째 뷰"를 기본값으로 쓰지 않는다.
- **완료로 거르지 않는 뷰**("내 작업", "오늘" 등)에서는 체크해도 항목이 남는다(Notion과 같음). 앱·위젯은
  체크한 항목을 취소선과 함께 아래로 내린다.
- 뷰 필터에서 완료 속성을 추론할 수 없으면(필터 없음 등) title 외 status → checkbox 순으로
  DB에 하나뿐인 속성을 쓰고, 그래도 모호하면 읽기 전용으로 표시한다.
- "작업 데이터베이스로 지정"(Turn into Tasks) 여부는 API에 노출되지 않으므로 쓰지 않는다.

## 플랫폼

| 플랫폼 | 앱 | 위젯 | 비고 |
|---|---|---|---|
| iPhone | SwiftUI | 홈화면·**잠금화면**·StandBy | |
| iPad | SwiftUI (같은 iOS 타깃) | 홈화면·잠금화면 | 큰 위젯 크기 대응 |
| Mac | SwiftUI **네이티브 macOS 타깃** | 데스크톱·알림센터 | "Designed for iPad" 실행이 아니라 macOS용으로 빌드 |

위젯 인터랙션(AppIntent 버튼·토글) 때문에 최소 iOS/iPadOS 17, macOS 14가 하한이다.
실제 최소 버전은 열린 결정 참고.

### 잠금화면 위젯

"항상 보이는 메모"에 가장 가까운 자리라 1급으로 지원한다.

| 크기 (`accessory*`) | 내용 |
|---|---|
| 직사각형 (`accessoryRectangular`) | 맨 위 할 일 2~3줄 + 남은 개수 |
| 원형 (`accessoryCircular`) | 남은 개수 |
| 인라인 (`accessoryInline`, 시계 위 한 줄) | 맨 위 할 일 1개 |

- 잠금화면 위젯은 단색으로 그려진다. 색에 의존하지 않는 레이아웃이어야 한다.
- 잠긴 상태에서도 갱신되려면 위젯이 Keychain 토큰을 읽을 수 있어야 한다 → 토큰은
  `kSecAttrAccessibleAfterFirstUnlock`으로 저장한다 (기본값 `WhenUnlocked`면 잠긴 동안 갱신 실패).
- **잠금 상태에서도 위젯 체크가 된다.** 체크(완료 토글) 인텐트만 잠금 해제 없이 허용하고, 추가·삭제·
  수정은 잠금 해제를 요구한다. 위젯 캐시 파일도 잠금 중 읽기·쓰기 가능한 보호 등급을 쓴다
  ([PLAN](docs/PLAN.md) 4.5).
- 같은 `accessory*` 위젯이 Apple Watch 컴플리케이션으로도 쓰일 수 있다 (범위 밖, 추후 검토).
- iPhone 충전 중 가로 거치(StandBy)에서는 홈화면 위젯이 크게 표시된다 — 책상 위 "메모판" 용도.

## 아키텍처

### 1단계 — 데이터 서버 없음 (구현됨)

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

- **하는 일:** `POST /v1/oauth/token` 프록시 2종(코드 교환, 토큰 갱신) + OAuth 리다이렉트(결과를 앱 주소
  `notiontodo://oauth`로 넘긴다 — 도메인 연결 설정이 필요 없다)
- **안 하는 일:** 토큰·사용자 데이터 저장, Notion 데이터 조회. 무상태이며 로그를 남기지 않는다
- **호출 빈도:** 로그인 1회 + 토큰 갱신 시. 사용자당 하루 수 회 이하
- **비용:** 서버리스 무료 플랜 범위 (Vercel Hobby·Cloudflare Workers 무료 티어 어느 쪽이든 충분). 사실상 0원
- **직접 빌드하는 사용자:** 자기 Notion public integration + 자기 함수 배포, 또는 Notion 개인 액세스 토큰을
  붙여 넣는 대체 경로를 쓴다 (internal integration 토큰도 된다)

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

### 디렉터리 구조

```
apps/
  project.yml            XcodeGen 정의 (NotionTodo.xcodeproj는 여기서 생성, 커밋돼 있음)
  Config/                xcconfig — 개인 값은 Local.xcconfig (커밋 안 함)
  Packages/              Swift 패키지
    NotionKit/             Notion HTTP 클라이언트 (Notion-Version 2026-03-11, 필터는 JSON 통과)
    TodoCore/              뷰 해석·완료 추론, App Group 캐시, 오프라인 대기열, Keychain, OAuth
    DesignSystem/          디자인 토큰, 체크 원, Liquid Glass 입력 바
  NotionTodo/            앱 (iPhone·iPad·Mac 멀티플랫폼 타깃)
  NotionTodoWidgets/     위젯 확장 (목록·개수·제어 위젯)
  Shared/                앱·위젯 공용 앱 인텐트 (체크, 추가, 뷰 선택, 딥링크)
  NotionTodoUITests/     UI 테스트 (추가 → 체크 → 실행 취소 → 삭제, 실제 Notion)
  NotionTodoWidgetsTests/ 위젯 스냅샷 (크기 × 라이트/다크 × 글자 크기)
auth/                    OAuth 토큰 교환 함수 (Vercel 배포, Cloudflare Workers 겸용, 무상태)
scripts/                 API 검증 스크립트, 앱 아이콘 생성
docs/                    계획·결정·배포 절차
server/                  (2단계, 미구현) Notion webhook 수신 + APNs 발송
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
5. **Notion 접근 권한.** 앱은 OAuth 로그인 때 사용자가 고른 페이지·DB와 앱이 만든 메모 DB에만 접근한다.
   그중 앱 목록·위젯에 보이는 것은 앱에서 고른 DB뿐이다. 할 일 DB가 접근 범위에서 빠졌으면 `DB 추가…`의
   "Notion에서 고르기"로 OAuth를 다시 띄운다. 개인 액세스 토큰은 사용자 권한을 그대로 쓰므로 고를 DB 목록은
   최근에 고친 30개까지 보여준다.
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
     상대값이므로 날짜가 바뀌면 Notion이 새 날짜로 계산한다. 위젯은 자정 직후 갱신을 예약한다
   - 뷰 쿼리(`/views/{id}/queries`) 결과에는 **페이지 ID만** 온다 → 제목을 보려면 페이지마다 추가 요청.
   - data source 쿼리도 `"me"`·`"today"`를 그대로 받고 같은 결과를 낸다 → 위젯은 **뷰 정의를 읽어
     `filter`+`quick_filters`+`sorts`로 data source 쿼리 1회**를 보내 속성까지 한 번에 받는다

## 직접 빌드하기

필요: macOS 26 이상, Xcode 26 이상 (Xcode 27이면 iOS 27 세로형 초대형 위젯까지).

1. `apps/Config/Local.xcconfig.example`을 `apps/Config/Local.xcconfig`로 복사하고 팀 ID·번들 ID 접두사를 넣는다.
2. `apps/NotionTodo.xcodeproj`를 열고 `NotionTodo` 스킴을 iPhone·iPad·Mac 중 원하는 대상으로 실행한다.
   (`project.yml`을 고쳤다면 `brew install xcodegen && cd apps && xcodegen`으로 다시 생성.)
3. 연결 — 둘 중 하나:
   - **Notion 연결하기**: [auth/README.md](auth/README.md)대로 함수를 배포(또는 로컬에서 실행)하고 client ID·주소를
     `Local.xcconfig`에 넣는다.
   - **토큰**: [Notion 개인 액세스 토큰](https://www.notion.so/developers/tokens)을 만들어(Notion API 켜기) 앱 첫 화면의
     "토큰으로 연결하기"에 붙여 넣는다. 함수 배포도, 페이지 공유도 필요 없다.

### 테스트

```sh
swift test --package-path apps/Packages            # 뷰 해석·저장소·클라이언트·색 대비 단위 테스트 (실제 응답 픽스처)
cd auth && npm test                                # 토큰 교환 함수

# 실제 Notion에 붙는 테스트 (테스트용 토큰과 DB 필요)
NT_LIVE_TOKEN=<토큰> swift test --package-path apps/Packages --filter Live
# UI 테스트 6개: 추가→체크→실행 취소 / 뷰 전환 / 오프라인 추가 후 복구 / 첫 실행 연결 / DB 더하고 빼기(iOS만) /
# 끌어서 순서 바꾸기와 섹션(iOS만). iOS는 -destination 'id=<시뮬레이터>'
# 문맥 메뉴의 "섹션으로 이동"은 4분쯤 걸려서 TEST_RUNNER_NT_SLOW_UI=1일 때만 돈다.
TEST_RUNNER_NT_DEV_TOKEN=<토큰> xcodebuild test -project apps/NotionTodo.xcodeproj -scheme NotionTodo \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=

# 위젯 스냅샷 PNG
TEST_RUNNER_SNAPSHOT_DIR=/tmp/widget-snapshots xcodebuild test -project apps/NotionTodo.xcodeproj \
  -scheme WidgetSnapshots -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

디버그 빌드는 `NT_DEV_TOKEN` 환경 변수가 있으면 그 토큰으로 바로 로그인한다(Keychain을 쓰지 않음). UI 테스트가 이 경로를 쓴다.
`NT_DEV_SIGNED_OUT=1`이면 로그인하지 않은 상태로 온보딩부터 시작하고, 연결해도 메모리에만 둔다.
`NT_DEV_OFFLINE=1`을 함께 주면 모든 요청이 "인터넷 연결 없음"으로 실패한다(오프라인 UI 테스트용).
`NT_DEV_RESET_LAYOUTS=1`은 기기에만 있는 순서·섹션을 지우고 시작한다. `NT_DEV_STORE_DIR=<폴더>`는 App Group 대신
그 폴더를 저장소로 쓰고, Mac에서 `NT_DEV_SNAPSHOT_DIR=<폴더>`를 주면 떠 있는 창을 1초마다 PNG로 적는다
(화면을 볼 수 없을 때 모양 확인용).

## 사용 흐름

1. Notion으로 로그인 → 앱에서 쓸 할 일 DB 고르기 (없으면 새 메모 DB를 만들어 준다)
2. 위젯 추가 → (원하면) 위젯 편집에서 Notion 뷰 선택
3. 끝 — 속성 지정 없음
4. (원하면) 앱에서 줄을 끌어 순서를 정하고, 색 카드 섹션으로 묶는다. 이 배치는 기기에만 저장되고 Notion은 그대로다

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
- [x] 최소 OS: iOS·iPadOS·macOS 26 (Liquid Glass 기준, 2026-11-09)
- [ ] 배포 채널 — App Store / TestFlight 공개 베타 / 소스 빌드만
- [x] 속성 매핑 없이 Notion 뷰 기반 위젯 + OAuth 로그인 (2026-11-08)
- [x] 토큰 교환 함수 호스팅 — Vercel (`notion-todo-auth.vercel.app`, 2026-11-09). 같은 코드가 Cloudflare Workers에서도 돈다
- [x] 위젯 체크 토글을 첫 릴리스에 포함 — 잠금 상태에서도 (2026-11-09)
- [ ] 2단계 중계 서버 도입 여부

## 기여

설계 논의는 이슈로, 결정은 [docs/DECISIONS.md](docs/DECISIONS.md)에 기록한다. PR은 CI(단위 테스트,
iOS·macOS 빌드, 위젯 스냅샷, 함수 테스트)를 통과해야 한다. PR에 Notion 토큰·팀 ID·`Local.xcconfig`가
섞이지 않게 주의한다. 새 문자열은 `Localizable.xcstrings`에 한국어 번역을 같이 넣는다.

## 참고

- [Notion Webhooks](https://developers.notion.com/reference/webhooks)
- [Event types & delivery](https://developers.notion.com/reference/webhooks-events-delivery)
- [2025-09-03 업그레이드 가이드](https://developers.notion.com/docs/upgrade-guide-2025-09-03)
- [Working with views](https://developers.notion.com/guides/data-apis/working-with-views)
- [Authorization (OAuth)](https://developers.notion.com/docs/authorization)
- [Status 속성 그룹](https://developers.notion.com/reference/update-property-schema-object)

## 라이선스

MIT — [LICENSE](LICENSE)
