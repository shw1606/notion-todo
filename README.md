# notion-todo

Notion 데이터베이스를 단일 진실 소스로 쓰는 오픈소스 투두 앱. **iPhone · iPad · Mac** 세 플랫폼에서
동작하고, 세 플랫폼 모두 홈화면/데스크톱 위젯에서 바로 체크할 수 있다.

> **EN:** An open-source todo app backed by your own Notion database, with native SwiftUI +
> WidgetKit apps and interactive widgets on iPhone, iPad and Mac. Phase 1 talks to Notion
> directly from the app and widgets using your own Notion integration token — no server
> required. An optional self-hosted relay (Notion webhook → APNs widget push) comes later
> for near-instant widget refresh. Scaffold stage — no implementation yet.

**상태:** 스캐폴드 (2026-11-08). 구현 코드 없음.

---

## 왜 만드나

기존 서드파티 앱(Widget for Notion, WFN, Nutshell 등)은 iPhone 중심이고, Mac에서는 iPad 앱을
그대로 돌리거나 Mac 전용 앱이 따로 있다. 실제로 Mac에서 써본 결과 바로 동작하지 않았다.
**세 플랫폼을 하나의 네이티브 코드베이스로, 오픈소스로** 제공하는 앱이 목표다.

## 목표

1. 자기 Notion DB의 투두 항목을 iPhone·iPad·Mac에서 읽고, 완료 토글까지 양방향 반영
2. 세 플랫폼 모두 **인터랙티브 위젯** — 위젯에서 바로 체크 (AppIntent)
3. 어떤 DB 스키마든 연결 가능 — 사용자가 제목·완료·기한 등 속성을 앱에서 매핑
4. 서버 없이 동작 — 사용자가 자기 Notion 인티그레이션 토큰만 넣으면 끝
5. 변경이 수 분 내 반영 (아래 제약 3번 참고 — "실시간"은 위젯에서 성립하지 않는다)

## 플랫폼

| 플랫폼 | 앱 | 위젯 | 비고 |
|---|---|---|---|
| iPhone | SwiftUI | 홈화면·잠금화면 | |
| iPad | SwiftUI (같은 iOS 타깃) | 홈화면 | 큰 위젯 크기 대응 |
| Mac | SwiftUI **네이티브 macOS 타깃** | 데스크톱·알림센터 | "Designed for iPad" 실행이 아니라 macOS용으로 빌드 |

위젯 인터랙션(AppIntent 버튼·토글) 때문에 최소 iOS/iPadOS 17, macOS 14가 하한이다.
실제 최소 버전은 열린 결정 참고.

## 아키텍처

### 1단계 — 서버 없음 (현재 계획)

```
Notion API
   ▲  조회 / 완료 토글 (사용자 본인의 인티그레이션 토큰, App Group 공유 Keychain)
   │
   ├── iOS/iPadOS 앱 + 위젯 (SwiftUI + WidgetKit, AppIntent 토글)
   └── macOS 앱 + 위젯      (같은 코드, 멀티플랫폼 타깃)
```

- 앱을 열면 Notion을 직접 조회 → 즉시 반영
- 위젯 체크 토글은 AppIntent에서 Notion API를 직접 호출
- 위젯 타임라인 갱신 시 Notion을 직접 조회 → 다른 곳에서 바꾼 내용은 15~60분 내 반영
- 사용자마다 자기 인티그레이션 토큰을 쓰므로 레이트리밋도 사용자별로 분리된다

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
  Shared/        Notion 클라이언트, 모델, 속성 매핑, Keychain
  App/           SwiftUI 앱
  Widgets/       WidgetKit 확장 + AppIntent
  Config/        xcconfig (팀 ID·번들 ID 접두사는 Local.xcconfig로 분리, 커밋 안 함)
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
5. **Notion 인티그레이션 권한.** 사용자는 자기 워크스페이스에 internal integration을 만들고,
   소스 DB를 그 인티그레이션에 **명시적으로 공유**해야 읽기·쓰기가 가능하다. 앱 온보딩에서 안내한다.
   (public OAuth는 client secret 보관용 서버가 필요하므로 1단계에서는 쓰지 않는다.)
6. **토큰 보관.** 토큰은 App Group 공유 Keychain에만 저장한다. 소스 코드·번들·로그·분석 도구로
   내보내지 않는다. 앱은 서드파티 분석/트래킹 SDK를 넣지 않는다.
7. **스키마 다양성.** 사용자마다 DB 구조가 다르다. 완료는 checkbox 또는 status 속성, 기한은 date
   속성 등으로 매핑을 받고, 매핑이 깨지면(속성 삭제·타입 변경) 위젯에 명확한 오류를 띄운다.

## 직접 빌드하기 (구현 후 채움)

1. `apps/Config/Local.xcconfig.example`을 `Local.xcconfig`로 복사하고 자기 팀 ID·번들 ID 접두사 입력
2. Xcode에서 iOS 또는 macOS 스킴 빌드
3. 앱 온보딩에서 Notion 인티그레이션 토큰 입력 → DB 선택 → 속성 매핑

## 설정

1단계(앱)는 Notion 토큰과 DB를 앱 온보딩에서 입력받아 Keychain에 저장한다. 환경 변수가 없다.

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
- [ ] 기본 스키마: 최소 필드(제목·완료·기한·우선순위·프로젝트)와 매핑 UI 범위
- [ ] 위젯 체크 토글을 첫 릴리스에 포함할지, 읽기 전용으로 시작할지
- [ ] 2단계 중계 서버 도입 여부

## 기여

아직 스캐폴드 단계다. 설계 논의는 이슈로, 결정은 [docs/DECISIONS.md](docs/DECISIONS.md)에 기록한다.
PR에 Notion 토큰·팀 ID·`Local.xcconfig`가 섞이지 않게 주의한다.

## 참고

- [Notion Webhooks](https://developers.notion.com/reference/webhooks)
- [Event types & delivery](https://developers.notion.com/reference/webhooks-events-delivery)
- [2025-09-03 업그레이드 가이드](https://developers.notion.com/docs/upgrade-guide-2025-09-03)

## 라이선스

MIT — [LICENSE](LICENSE)
