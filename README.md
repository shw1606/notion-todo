# notion-todo

Notion 데이터베이스를 단일 진실 소스로 쓰는 투두 시스템. macOS·iOS 양쪽에 동기화 + 위젯.

> **EN:** A todo system backed by a Notion database as the single source of truth, with a
> self-hosted relay server and native widgets on macOS and iOS. Design notes and the
> real-world constraints (Notion webhook semantics, WidgetKit refresh budget, Apple
> signing requirements) are documented below. Scaffold stage — no implementation yet.

**상태:** 스캐폴드 (2026-11-08). 구현 코드 없음. 소스 DB 선택 대기 중.

---

## 목표

1. Notion DB의 투두 항목을 macOS·iOS에서 읽고, 완료 토글까지 양방향 반영
2. 양 기기 **위젯** — 홈화면/알림센터에서 오늘 할 일 확인
3. 변경이 수 분 내 반영 (아래 제약 3번 참고 — "실시간"은 위젯에서 성립하지 않는다)

## 아키텍처 (계획)

```
Notion DB
   │  webhook: data_source.content_updated  (Notion-Version 2025-09-03)
   ▼
셀프호스팅 중계 서버
   │  정규화 + 캐시 + 폴링 백업
   │  loopback 바인딩 + 인증된 리버스 프록시로만 노출
   ├──────────────► iOS 클라이언트 / 위젯
   └──────────────► macOS 클라이언트 / 위젯
```

중계 서버를 먼저 세우는 것이 핵심이다. 클라이언트를 경로 A(스크립트)에서 B(네이티브)로
올려도 서버는 그대로 재사용되므로 버리는 작업이 없다.

### 계획 디렉터리 구조

```
server/        중계 API (Node). Notion webhook 수신 + 캐시 + 클라이언트용 REST
clients/ios/   경로 A: Scriptable 위젯 (JS) / 경로 B: SwiftUI + WidgetKit
clients/mac/   경로 A: SwiftBar 플러그인 / 경로 B: 동일 Xcode 타깃
docs/          설계·결정 기록
```

## 클라이언트 경로 선택

| 경로 | iOS 위젯 | macOS 위젯 | 비용/빌드 |
|---|---|---|---|
| **A. Scriptable + SwiftBar** | ○ JS로 렌더 | △ 메뉴바 아이템 (진짜 위젯 아님) | 0원, Apple 빌드 환경 불필요 |
| **B. 네이티브 SwiftUI + WidgetKit** | ◎ 위젯에서 체크 토글 (AppIntent) | ◎ 같은 코드로 macOS 위젯 | Xcode 필요, 연 $99 권장 |

## 제약 — 설계에 반드시 반영할 것

1. **경로 B는 macOS 빌드 머신이 필요하다.** Xcode는 macOS 전용이므로 Linux 서버에서
   컴파일·서명·설치가 불가능하다. 소스·프로젝트 파일 작성과 빌드 환경을 분리해서 생각해야 한다.
2. **Apple 서명:** 무료 개발자 계정은 7일마다 재서명·재설치가 필요하다. 상시 사용은
   Apple Developer Program(연 $99)이 사실상 전제다.
3. **iOS 위젯은 실시간이 아니다.** WidgetKit 타임라인 갱신은 OS 예산 제약을 받는다
   (실측 15~60분 간격). 즉시 반영 경로는 APNs 푸시로 위젯을 강제 리로드하는 방법뿐이고,
   이것도 유료 계정이 필요하다.
   → 동기화의 현실적 정의: **앱 내부는 즉시, 위젯은 수 분~수십 분.**
4. **Notion 레이트리밋** 평균 3 req/s. webhook 페이로드는 메타데이터만 오므로 이벤트 수신 후
   재조회가 필요하다 → 캐시 없이 위젯이 Notion을 직접 호출하는 설계는 금지.
5. **Notion 인티그레이션 권한.** Notion MCP 연결과 서버의 인티그레이션 토큰은 권한이 별개다.
   소스로 쓸 DB는 서버가 사용하는 인티그레이션에 **명시적으로 공유**해야 읽기·쓰기가 가능하다.

## 설정

중계 서버는 `.env`로 설정한다 (`.env`는 커밋하지 않는다).

| 변수 | 설명 |
|---|---|
| `NOTION_API_KEY` | Notion 인티그레이션 토큰 |
| `NOTION_DATA_SOURCE_ID` | 투두 소스 data source ID |
| `NOTION_WEBHOOK_SECRET` | `X-Notion-Signature` HMAC 검증용 |
| `CLIENT_API_KEY` | 클라이언트 → 중계 서버 인증 키 |

## 열린 결정

- [ ] **소스 DB**: 기존 DB 재사용 vs 신규 생성 — 미정
- [ ] 클라이언트 경로 A / B
- [ ] 스키마: 최소 필드(제목·완료·기한·우선순위·프로젝트) 확정
- [ ] 쓰기 방향 — 위젯 체크 토글을 1단계에 포함할지, 읽기 전용으로 시작할지

## 참고

- [Notion Webhooks](https://developers.notion.com/reference/webhooks)
- [Event types & delivery](https://developers.notion.com/reference/webhooks-events-delivery)
- [2025-09-03 업그레이드 가이드](https://developers.notion.com/docs/upgrade-guide-2025-09-03)

## 라이선스

MIT — [LICENSE](LICENSE)
