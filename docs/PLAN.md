# 구현 계획 — 디자인 방향과 전체 앱·위젯

작성 2026-11-09, 구현 반영 2026-11-09. 기준 SDK: Xcode 27.2 / iOS·iPadOS·macOS 27.2 (설치된 SDK에서 API 존재 확인).
설계 배경과 결정은 [README](../README.md)와 [DECISIONS](DECISIONS.md) 참고. 이 문서는 **무엇을 어떤 순서로,
어떤 모양으로 만드는지**를 정한다.

---

## 구현 현황 (2026-11-09)

| # | 상태 | 비고 |
|---|---|---|
| M0 골격 | ✅ | XcodeGen 프로젝트, 앱·위젯 멀티플랫폼 타깃, 패키지 3개, xcconfig, CI(`.github/workflows/ci.yml`) |
| M1 NotionKit + TodoCore | ✅ | 단위 테스트 47개(실제 응답 픽스처, 색 대비·로그인 교환·새 메모 DB 포함) + 실제 Notion 통합 테스트(체크박스·Status DB 왕복, 토큰 로그인) |
| M2 iPhone 앱 | ✅ | 목록·유리 입력 바·체크 손맛·스와이프·뷰 전환·오프라인 대기열, UI 테스트 4개 통과(iPhone 시뮬레이터, 첫 실행 연결 포함) |
| M3 홈화면 위젯 | ✅ | 목록·개수 위젯, 뷰 선택, 위젯 체크, 스냅샷 169장(크기 × 렌더링 모드 × 라이트/다크 × 글자 크기) |
| M4 잠금화면·StandBy·제어 | ✅ 코드 / ⏳ 실기기 | 잠금 중 체크 허용 인텐트, 제어 위젯, Siri. 실기기 확인은 [RELEASE.md](RELEASE.md) 3장 |
| M5 iPad·Mac | ✅ | 분할 화면, 창마다 다른 뷰, 키보드(⌘N·⌘R·Space·⌫), 포인터 호버, 초대형·세로형 위젯, 메뉴 막대, UI 테스트 3개 통과(Mac) |
| M6 OAuth·온보딩 | ✅ 코드 / ⏳ 배포 | `auth/` 함수(테스트 10개, 실제 Notion 토큰 갱신 확인), 연결 버튼 하나 → 시작할 목록 추천 → 위젯 안내(플랫폼별), 토큰 붙여넣기 연결, 설정에서 페이지 더 고르기. 로컬 함수로 Mac에서 동의 화면·콜백·교환 경로 확인. 배포는 계정 필요 |
| M7 다듬기 | ✅ | 한국어·영어, VoiceOver 레이블, 동작 줄이기, Dynamic Type(위젯 줄 수 자동 축소) |
| M8 배포 | ⏳ | 계정이 필요한 단계 — [RELEASE.md](RELEASE.md) |

계획과 달라진 점:
- **⌘N은 새 메모, 새 창은 ⌥⌘N** (메모·미리 알림 앱과 같게).
- **리스트 순서 바꾸기(`reorderable`)는 뺐다.** Notion API로는 뷰의 수동 정렬 순서를 바꿀 수 없다.
- **기본 뷰**: "첫 번째 뷰"가 아니라 할 일을 보여주는 뷰를 고른다 (API 목록 순서 ≠ 탭 순서).
- **완료로 거르지 않는 뷰**는 체크해도 항목이 남고 아래로 내려간다 (`filtersByCompletion`).
- **세로형 초대형 위젯**은 iOS·macOS 27 SDK(WidgetKit 749+, Xcode 27.2에서 확인)로 빌드할 때만 들어간다 —
  Xcode 26으로도 나머지는 빌드된다(CI는 Xcode 26.6).
- **제어 위젯·위젯 `+`는 `OpenComposerIntent` 대신 `OpenURLIntent`(딥 링크 `notiontodo://compose`)**로 앱을 연다.
  위젯 확장만으로 동작하고 앱 쪽 인텐트 등록이 필요 없다.
- **`widgetAccentedRenderingMode`는 쓰지 않는다.** 위젯 아이콘이 모두 SF Symbol이라 `widgetAccentable()`로 충분하다
  (컬러 이미지용 API). 대신 체크된 원은 틴트·단색 모드에서 체크 표시를 원에서 도려내 모양으로 남긴다.
- **스냅샷 테스트는 기준 이미지 비교 대신 PNG 산출물**을 만든다(CI 아티팩트). 폰트·OS 차이로 픽셀 비교가 불안정하다.
- **체크가 실패하면 되돌리지 않고 대기(흐린 원)로 남겨 다시 보낸다** (4.5의 "되돌리고 오류 배지" 대신).
  잠금화면·오프라인에서 한 체크가 사라지지 않게 하려는 것이다. 되돌릴 수 없는 오류로 세 번 실패하면 버리고,
  다음 조회에서 Notion 상태로 돌아간다. VoiceOver는 대기 중인 항목을 "동기화 대기 중"으로 읽는다.
- **앱은 캐시로 먼저 열고** Notion 응답은 뒤에서 덮는다 (시작할 때 네트워크를 기다리는 스피너 없음).
- **로그인 콜백은 HTTPS(Associated Domains) 대신 앱 주소**다. `auth/`의 `/callback`이 code·state를 `notiontodo://oauth`로
  넘기고 인증 창이 그 이동을 가로챈다. 도메인 연결(AASA)·서명 설정이 필요 없고, 가로챈 code는 PKCE 때문에 쓸모가 없다.
- **Mac은 기본 브라우저가 Safari일 때만 인증 창**을 쓴다. Chrome 계열이 기본 브라우저면 인증 창이 두 번째부터
  뜨지 않고 멈추는 macOS 문제가 있어서, 새 탭으로 열고 앱 주소로 돌아오게 한다. 기다리는 동안은 언제든 취소할 수 있다.
- **온보딩에서 페이지를 고르지 않는다.** Notion 동의 화면에서 "액세스 허용"만 눌러도 되고, 새 메모 DB는 워크스페이스
  맨 위(사용자의 "개인 페이지")에 만든다. 그럴 수 없는 internal integration만 공유된 맨 위 페이지 아래에 만든다.
- **토큰 연결은 개인 액세스 토큰을 권한다.** 내 권한을 그대로 써서 페이지를 통합에 공유하는 단계가 없다.
  그래서 연결이 워크스페이스 전체를 볼 수 있으므로, 뷰 목록은 최근에 고친 DB 30개까지만 3개씩 동시에 받는다.

---

## 0. 한 줄 요약

**"유리 위의 메모"** — 메모(콘텐츠)는 종이처럼 선명하게, 그 위에 떠 있는 조작 층만 Liquid Glass로.
iPhone·iPad·Mac 앱 하나(멀티플랫폼 타깃)와 위젯 확장 하나로, 홈화면·잠금화면·StandBy·데스크톱·
제어 센터까지 덮는다. 1순위 경험은 **빠른 기록**과 **항상 보이는 위젯에서의 체크**.

## 1. 범위

### 만든다
| 표면 | iPhone | iPad | Mac |
|---|---|---|---|
| 앱 (목록·빠른 기록·뷰 전환·설정·온보딩) | ✅ | ✅ 분할 화면 | ✅ 사이드바 창 |
| 홈화면/데스크톱 위젯 (small·medium·large) | ✅ | ✅ + extra large | ✅ + extra large |
| 세로형 초대형 위젯 (`systemExtraLargePortrait`, OS 27+) | — | ✅ | ✅ |
| 잠금화면 위젯 (`accessory*`) | ✅ | ✅ | — |
| StandBy | ✅ (small 위젯 재사용) | — | — |
| 제어 위젯 "메모 추가" (Control) | ✅ 제어 센터·잠금화면·동작 버튼 | ✅ | ✅ 제어 센터·메뉴 막대 |
| 메뉴 막대 빠른 기록 (`MenuBarExtra`) | — | — | ✅ |
| Siri·단축어 (`AppShortcuts`) | ✅ | ✅ | ✅ |
| OAuth 토큰 교환 함수 (`auth/`) | 공통 | | |

### 만들지 않는다 (이번 계획 밖)
- Apple Watch 앱·컴플리케이션 (accessory 위젯을 재사용할 수 있게 설계만 열어 둠)
- 2단계 중계 서버(webhook → APNs 위젯 푸시). `WidgetPushHandler`가 SDK에 있으므로 나중에 붙일 자리만 남긴다
- 여러 Notion 계정 동시 로그인, 공유·협업 기능, 리치 텍스트 편집
- 서드파티 분석/트래킹 SDK

### 최소 OS — 확정: iOS·iPadOS·macOS 26 (2026-11-09)
Liquid Glass와 위젯의 tinted/clear 외형이 26에서 시작한다. 26을 하한으로 두면 디자인 분기 없이 한 벌로 간다.
27 전용 기능(`systemExtraLargePortrait`, 리스트 `reorderable`)은 `#available(iOS 27, macOS 27, *)`로만 켠다.
→ DECISIONS 2026-11-09 기록.

---

## 2. 디자인 방향

### 2.1 원칙

1. **콘텐츠는 종이, 조작은 유리.** Liquid Glass는 내비게이션 막대·툴바·입력 바·떠 있는 버튼에만 쓴다.
   메모 행·카드·목록 배경에는 쓰지 않는다. 유리 위에 유리를 겹치지 않는다.
2. **표준 컴포넌트가 먼저.** `NavigationStack`·`NavigationSplitView`·`List`·`toolbar`·`Menu`·시스템 시트를
   쓰면 OS가 Liquid Glass와 스크롤 가장자리 효과를 알아서 입힌다. 직접 그린 크롬은 입력 바 하나뿐이다.
3. **기록이 1초 안에.** 앱을 열면 커서가 이미 입력 바에 있다. Return으로 추가하고 포커스는 유지된다.
   제목 외에 묻는 것이 없다.
4. **체크에는 손맛.** 체크 → 원이 채워지고 햅틱 → 글자에 취소선·흐림 → 0.8초 뒤 목록에서 빠진다.
   그 0.8초가 실행 취소 구간이다. Notion에서 체크했을 때 뷰에서 빠지는 동작과 같다.
5. **시스템 설정을 존중.** 투명도 줄이기·대비 증가·동작 줄이기·Dynamic Type·VoiceOver를 모든 화면과
   위젯에서 지원한다. 유리는 투명도 줄이기에서 시스템이 불투명하게 바꾸므로 그 상태에서도 읽혀야 한다.

### 2.2 디자인 토큰

`DesignSystem` 패키지 한 곳에서 정의하고 앱·위젯이 같이 쓴다.

**색**
| 토큰 | 값 | 쓰임 |
|---|---|---|
| `accent` | 앰버 계열 (라이트 `#B7791F` / 다크 `#F6B73C`, 구현 시 대비 4.5:1 이상 검증) | 체크 원 채움, 주요 유리 버튼 틴트, 남은 개수 숫자 |
| `ink` | `Color.primary` | 메모 본문 |
| `inkDone` | `Color.secondary` + 취소선 | 체크 직후 행 |
| `meta` | `Color.secondary` | 날짜 칩·보조 속성 |
| `paper` | `systemBackground` / 그룹 배경 | 목록 배경 (유리 아님) |
| `danger` | `Color.red` | 오류 배지, 삭제 스와이프 |

강조색은 화면당 한 곳 이상 쓰지 않는다. 위젯의 tinted 모드에서는 시스템이 `accent`를 사용자 틴트로 바꾼다.

**글자**
| 토큰 | 스타일 | 쓰임 |
|---|---|---|
| `title` | `.largeTitle` (내비게이션 큰 제목) | 뷰 이름 ("할 일") |
| `row` | `.body`, 최대 3줄 | 메모 본문 |
| `rowCompact` | `.subheadline`, 1~2줄 | 위젯 행 |
| `count` | `.title`·`.largeTitle` + `.fontDesign(.rounded)` + `monospacedDigit()` | 남은 개수 |
| `meta` | `.caption` | 날짜 칩 |

전부 텍스트 스타일 기반이라 Dynamic Type을 그대로 따른다. 숫자만 둥근 서체로 써서 메모 느낌을 준다.

**모양·간격**
- 모서리는 고정 반경 대신 `ConcentricRectangle`·`ContainerRelativeShape`로 바깥 용기와 동심원을 맞춘다
  (위젯 모서리, 시트 안 카드, 입력 바).
- 간격 4pt 배수: 4 / 8 / 12 / 16 / 24. 행 최소 높이 44pt(터치 영역).
- 체크 원 22pt, 터치 영역 44pt.

**동작**
- 체크: `.sensoryFeedback(.success, trigger:)` + 스프링. 동작 줄이기 켜면 크로스페이드만.
- 유리 요소 등장·전환: `GlassEffectContainer` 안에서 `glassEffectID`로 이어지는 모핑
  (예: 입력 바의 `+` 버튼 ↔ 전송 버튼).

### 2.3 Liquid Glass 사용 규칙 (코드 수준)

| 요소 | API | 비고 |
|---|---|---|
| 하단 입력 바 | `TextField`를 `.glassEffect(.regular.interactive(), in: .capsule)`로 감싸 `safeAreaBar(edge: .bottom)`에 고정 | 스크롤 콘텐츠가 밑으로 흐르고 가장자리 효과가 가독성을 지킨다 |
| 추가 버튼 | `.buttonStyle(.glassProminent)` + `accent` 틴트 | 입력 바와 같은 `GlassEffectContainer` |
| 툴바 버튼 (뷰 전환·설정) | 표준 `ToolbarItem` | OS가 유리를 입힌다. 직접 `glassEffect` 금지 |
| 실행 취소 토스트 | `.glassEffect(.regular, in: .capsule)` | 0.8초 구간 동안 하단에 뜬다 |
| 목록 행·메모 | 유리 없음 | 원칙 1 |
| 위젯 | **직접 유리 없음** | 아래 4.3 — 외형은 시스템 몫 |

배경에 그라디언트·이미지를 깔지 않는다. 유리는 그 아래 실제 콘텐츠(메모 목록)를 굴절할 때 의미가 있다.

---

## 3. 앱 화면 설계

### 3.1 공통 화면 흐름

```
첫 실행 ─► 온보딩 ─► 메인(첫 뷰) ◄──► 뷰 전환 메뉴
                         │
                         ├─► 설정 (계정·뷰·위젯 안내·정보)
                         └─► 항목 길게 누르기 → Notion에서 열기 / 삭제
```

### 3.2 온보딩 (버튼 세 번: 연결 → 시작 → 적기 시작)

키 발급·페이지 공유 같은 준비 없이 "Notion 연결하기" 한 번으로 시작한다 (Widget for Notion과 같은 흐름).

1. **소개 + 연결** — "적어 두고, 위젯에서 체크하세요." 아래에 번호 붙은 세 줄로 다음에 일어날 일을 미리 보여준다
   (Notion에 로그인 → ‘페이지 선택’ → ‘액세스 허용’, 페이지는 안 골라도 됨 → 적기 시작). 버튼 하나: `Notion 연결하기`.
   - iOS·Safari가 기본인 Mac: 인증 창(`ASWebAuthenticationSession`, 콜백 `notiontodo://oauth`).
   - 그 밖의 Mac: 기본 브라우저 새 탭 → 브라우저가 앱 주소를 열면 이어서 마친다. 기다리는 동안 `취소` 버튼.
   - Notion 화면에서 취소하거나 창을 닫으면 오류 없이 처음으로 돌아온다.
2. **시작할 목록** — "○○에 연결됐어요" 아래에 출발점을 **미리 골라 두고** 버튼 하나(`시작`)로 끝낸다.
   - 이 앱이 만든 메모 DB가 보이면 그것, 아니면 **새 메모 DB**(내용·완료·만든 시간, 할 일·완료함 뷰)를
     Notion 사이드바 "개인 페이지"에 만든다.
   - 체크박스·status가 있는 다른 DB도 아래에 나열하고, 각 줄에 체크하면 무엇이 바뀌는지 한 줄로 보여준다:
     "체크하면 ‘완료’에 체크됩니다" / "체크하면 ‘상태’ → ‘Done’". 고르면 할 일을 보여주는 뷰를 자동으로 연다.
   - 목록은 검색 한 번으로 만든다 (뷰는 고른 뒤에 받는다) — 워크스페이스가 커도 바로 뜬다.
   - 안 보이면 `Notion에서 고르기…`(인증 다시 → 페이지 선택 화면).
3. **위젯 안내** — 플랫폼별: iPhone·iPad는 홈 화면·잠금 화면·제어 센터, Mac은 데스크탑·알림 센터·메뉴 막대.

토큰으로 연결(OAuth 함수 없이 직접 빌드할 때·보조 경로): "토큰 만들기"(Notion 개인 액세스 토큰 페이지 열기) →
붙여넣기 버튼 또는 ⌘V → 바로 확인하고 2번으로. 토큰이 틀렸을 때·오프라인일 때 오류 문구를 따로 보여준다.

### 3.3 iPhone 메인

```
┌─────────────────────────────┐
│ 할 일 ▾                ⚙︎   │  ← 큰 제목 = 뷰 이름, ▾ = 뷰 전환 메뉴 (유리 툴바)
│                             │
│ ○ 치약 사기                  │
│ ○ 택배 반품 접수             │  ← 표준 List(.plain), 유리 없음
│ ○ 엄마 생일 선물 알아보기,    │     행: 체크 원 + 본문(최대 3줄) + 날짜 칩(뷰에 날짜 있을 때만)
│   예산 10만원                │
│                             │
│ ╭─────────────────────╮ ╭─╮ │
│ │ 메모 추가…           │ │+│ │  ← 유리 입력 바 + glassProminent 버튼, safeAreaBar
│ ╰─────────────────────╯ ╰─╯ │
└─────────────────────────────┘
```

- **체크**: 원 탭 → 2.1의 4번 동작. 오른쪽 스와이프도 체크.
- **삭제**: 왼쪽 스와이프 → Notion 페이지 휴지통 이동(`in_trash`). 실행 취소 토스트 제공.
- **수정**: 행 탭 → 그 자리에서 편집. Return 또는 포커스 해제 시 저장.
- **새로고침**: 당겨서 새로고침 + 앱 활성화 시 자동.
- **빈 상태**: `ContentUnavailableView` — "다 했어요 ✨" + 입력 바는 그대로.
- **오프라인**: 마지막 캐시를 보여주고 툴바에 작은 구름 아이콘. 오프라인에서 추가·체크한 것은
  대기열에 쌓았다가 연결되면 보낸다(행에 대기 표시).
- **완료 방식이 읽기 전용인 뷰**: 체크 원 대신 점(•)을 표시하고 탭하면 이유를 알려준다.

### 3.4 iPad

- `NavigationSplitView`: 사이드바 = DB별 뷰 목록(유리 사이드바는 시스템), 본문 = 3.3과 같은 목록 + 입력 바.
- 하드웨어 키보드: `⌘N` 입력 바 포커스, `Space` 선택 행 체크, `⌫` 삭제, `⌘R` 새로고침.
- 포인터 호버 시 행 강조. 여러 창(Stage Manager)에서 창마다 다른 뷰.
- 27+에서 `reorderable`은 수동 정렬 뷰에만 켠다(정렬 속성이 있는 뷰는 순서 변경 불가 안내).

### 3.5 Mac

- 같은 `NavigationSplitView` 창. 툴바는 macOS 유리 툴바(시스템).
- **메뉴 막대 빠른 기록** (`MenuBarExtra`, window 스타일): 아이콘 클릭 → 입력 바 + 상위 5개 목록.
  스티키 메모처럼 "어디서든 바로 적기"를 Mac에서 담당한다.
- 단축키: 앱 안 단축키는 iPad와 동일. 전역 단축키는 2차(별도 권한·라이브러리 필요).
- 창을 닫아도 메뉴 막대 아이콘은 남는다(설정에서 끌 수 있음).

### 3.6 설정

계정(로그인한 Notion 사용자·워크스페이스, 로그아웃) / 연결된 DB와 뷰(페이지 추가 선택 = OAuth 재실행) /
위젯(갱신 주기 설명, 마지막 갱신 시각, "지금 위젯 새로고침") / 접근성 미리보기 없음(시스템 설정 따름) /
정보(오픈소스 라이선스, GitHub 링크, 개인정보: "데이터는 기기와 Notion 사이에서만 오갑니다").

---

## 4. 위젯 설계

### 4.1 위젯 종류

위젯 확장 하나에 세 개를 둔다.

| 위젯 | 종류 | 설정 |
|---|---|---|
| **할 일 목록** | `AppIntentConfiguration` (홈·데스크톱·잠금화면·StandBy) | 뷰 선택 (`NotionViewEntity`) |
| **남은 개수** | `AppIntentConfiguration` (작은 크기·원형) | 뷰 선택 |
| **메모 추가** | `ControlWidget` (제어 센터·잠금화면·동작 버튼·Mac 메뉴 막대) | 없음 |

### 4.2 크기별 레이아웃

| 크기 | 내용 | 상호작용 |
|---|---|---|
| `systemSmall` | 뷰 이름 · 남은 개수(둥근 숫자) · 상위 3개(1줄씩) | 행별 체크 버튼 |
| `systemMedium` | 머리줄(뷰 이름·개수·`+`) · 상위 4개 | 행별 체크, `+`는 앱 입력 바로 열기 |
| `systemLarge` | 머리줄 · 상위 8~9개 | 행별 체크 |
| `systemExtraLarge` (iPad·Mac) | 2열 · 최대 16개 | 행별 체크 |
| `systemExtraLargePortrait` (27+) | 1열 · 최대 14개 | 행별 체크 |
| `accessoryRectangular` | 상위 2~3개 + "+N" | 행별 체크 (잠금 상태에서도, 4.5) |
| `accessoryCircular` | 남은 개수 (게이지 아님, 숫자) | 탭 → 앱 |
| `accessoryInline` | "할 일 3 · 치약 사기" | 탭 → 앱 |

넘치는 개수는 마지막 줄에 "+N개 더". 항목이 없으면 "다 했어요" + `+`.

### 4.3 렌더링 모드와 Liquid Glass

위젯 외형(유리·틴트·투명)은 **시스템이 입힌다.** 위젯 안에서 `glassEffect`를 쓰지 않는다.
대신 세 가지 렌더링 모드(`widgetRenderingMode`)에서 모두 읽히게 만든다.

| 모드 | 언제 | 처리 |
|---|---|---|
| `.fullColor` | 기본 홈화면·데스크톱 | `containerBackground(for: .widget)`에 `paper` 배경, `accent` 체크 원 |
| `.accented` | 홈화면 tinted/clear 외형 | 체크 원·개수에 `.widgetAccentable()`, 아이콘은 `widgetAccentedRenderingMode` 지정. 배경은 시스템이 제거·대체 |
| `.vibrant` | 잠금화면, StandBy 야간 | 단색 계층(`primary`/`secondary`)만으로 구분. 색에 의미를 싣지 않음 |

- `showsWidgetContainerBackground`가 false인 곳(StandBy 등)에서는 여백을 줄이고 글자를 키운다.
- 체크된 상태는 색이 아니라 **모양**(채운 원 + 취소선)으로 구분 — 모든 모드에서 동일하게 읽힌다.

### 4.4 데이터와 갱신

```
App Group 컨테이너
 ├─ cache/views/<viewId>.json     뷰 정의 (filter·quick_filters·sorts·스키마 요약) — 하루 1회 또는 앱에서 갱신
 ├─ cache/items/<viewId>.json     마지막 조회 결과 (위젯이 즉시 그릴 데이터)
 └─ queue/pending.json            오프라인·실패 대기 쓰기
Keychain (공유 access group, kSecAttrAccessibleAfterFirstUnlock)
 └─ access/refresh 토큰
```

- **타임라인**: `getTimeline`에서 캐시로 엔트리를 먼저 만들고, 짧은 제한 시간 안에 data source 쿼리
  1회로 새로 받아 덮는다. 정책은 `.after(now + 20분)`. 실제 주기는 OS 예산이 정한다.
- **자정 엔트리**: 뷰 필터에 날짜 조건이 있으면 다음 갱신을 `min(20분 뒤, 다음 자정 직후)`로 당긴다.
  Notion은 "today"를 상대값으로 저장하므로 자정 이후 쿼리는 새 날짜 기준으로 나온다.
- **앱이 바꾸면**: 앱에서 추가·체크·삭제 후 `WidgetCenter.shared.reloadTimelines(ofKind:)`.
- **쿼리 구성**: 뷰 정의의 `filter` ∧ `quick_filters` + `sorts` → `POST /v1/data_sources/{id}/query`,
  `page_size: 100` 한 번. 남은 개수와 "+N"은 이 결과로 센다. `has_more`면 "99+"로 표시하고 추가 페이지는
  부르지 않는다(위젯 갱신당 요청 1회 유지).

### 4.5 위젯 안 체크 (`ToggleTodoIntent`)

1. 버튼 = `Button(intent: ToggleTodoIntent(pageId:, viewId:))`.
2. `perform()`: 캐시에서 해당 항목을 "대기"로 표시 → 위젯 리로드 요청(즉시 반영처럼 보이게) →
   Notion PATCH → 성공하면 캐시에서 제거, 실패하면 되돌리고 오류 배지 + 대기열에 넣음.
3. 대기 중인 행은 `invalidatableContent()`로 흐리게.
4. **잠금 상태에서도 체크된다.** `ToggleTodoIntent`만 `authenticationPolicy = .alwaysAllowed`로 둔다.
   허용 범위는 **체크(완료 토글)뿐** — 추가·삭제·수정·뷰 변경 인텐트는 기본 정책(잠금 해제 요구)을 유지한다.
5. 잠긴 동안 인텐트가 돌려면 토큰(Keychain `AfterFirstUnlock`)과 App Group 캐시·대기열 파일
   (`FileProtectionType.completeUntilFirstUserAuthentication`)을 잠금 중에도 읽고 쓸 수 있어야 한다.
   `complete` 보호 등급을 쓰면 잠금 중 체크가 조용히 실패하므로 금지.

### 4.6 제어 위젯 "메모 추가"

- `ControlWidgetButton` + `OpenIntent` 계열 → 앱을 입력 바 포커스 상태로 연다.
- 잠금화면 하단·동작 버튼·제어 센터 어디서든 **한 번에 기록 화면**. 스티키 메모의 "아무 데나 휘갈기기"를
  담당하는 표면이다.
- Siri·단축어: `AddMemoIntent(text:)`를 `AppShortcuts`로 노출 — "할 일 메모에 치약 사기 추가".
  앱을 열지 않고 추가하고 위젯을 리로드한다.

### 4.7 위젯 상태별 화면

| 상태 | 표시 |
|---|---|
| 로그인 전 | "Notion에 로그인하세요" + 탭하면 온보딩 |
| 뷰 미선택 | 접근 가능한 첫 DB의 첫 뷰로 자동. 없으면 "앱에서 DB를 골라주세요" |
| 뷰 삭제됨·접근 불가 | "뷰를 찾을 수 없어요 — 위젯 편집에서 다시 선택" |
| 네트워크 실패 | 마지막 캐시 + 작은 "오프라인" 표시 + 마지막 갱신 시각 |
| 토큰 만료·취소 | "다시 로그인하세요" (Notion에서 연결을 끊은 경우 포함) |

---

## 5. 아키텍처

### 5.1 레포 구조

```
apps/
  NotionTodo.xcodeproj
  NotionTodo/              멀티플랫폼 앱 타깃 (iOS·iPadOS·macOS 목적지)
  NotionTodoWidgets/       위젯 확장 (목록·개수·제어 위젯), 멀티플랫폼
  Packages/
    NotionKit/             Notion HTTP 클라이언트 (Notion-Version 2026-03-11 고정)
    TodoCore/              뷰 해석·완료 추론·캐시·대기열·인증 토큰 저장/갱신
    DesignSystem/          토큰·공용 뷰(TodoRow, CheckCircle, GlassComposer, EmptyState, 위젯 행)
  Config/
    Base.xcconfig          공용 설정
    Local.xcconfig.example 팀 ID·번들 ID 접두사·OAuth client ID·auth 함수 URL (Local.xcconfig는 커밋 안 함)
auth/                      OAuth 토큰 교환 함수 (Cloudflare Workers 후보, TypeScript)
scripts/probe-views.mjs    API 검증 스크립트 (기존)
```

App Group ID와 Keychain access group은 `Local.xcconfig`의 팀·접두사로 조립한다 → 누구나 자기 계정으로 빌드.

### 5.2 NotionKit

- `NotionClient`: `URLSession` async, 토큰 주입, 429 `Retry-After` 존중 + 지수 백오프, 요청 타임아웃.
- 엔드포인트: `search`, `databases.get`, `dataSources.get/query`, `views.list/get`, `pages.create/update`,
  (온보딩용) `databases.create`, `views.create/update`.
- **필터는 모델링하지 않는다.** `filter`·`quick_filters`·`sorts`는 `JSONValue`(임의 JSON)로 받아
  그대로 합쳐 보낸다. Notion이 필터 종류를 늘려도 앱이 깨지지 않는다.
- 해석이 필요한 부분(완료 추론에 쓰이는 status/checkbox 조건)만 좁게 디코딩한다.

### 5.3 TodoCore

| 구성 | 책임 |
|---|---|
| `ViewResolver` | 뷰 정의 → `ResolvedView` (쿼리 본문, 제목 속성, 완료 방식, 날짜 속성, 표시 속성) |
| `CompletionStrategy` | `.checkbox(prop)` / `.status(prop, done: optionId, undo: optionId)` / `.readOnly(reason)` |
| `TodoRepository` | 조회·추가·체크·삭제, 캐시 읽기/쓰기, 낙관적 갱신 |
| `PendingQueue` | 실패·오프라인 쓰기 재시도 (앱 활성화·위젯 타임라인 때 소진) |
| `TokenStore` | Keychain (AfterFirstUnlock, 공유 access group) |
| `AuthService` | `ASWebAuthenticationSession`, 코드 교환·토큰 갱신(`auth/` 호출), 401 시 1회 갱신 후 재시도 |

**완료 추론 규칙** (`ViewResolver`)
1. `filter`와 `quick_filters`에서 `checkbox.equals == false` 또는 `does_not_equal == true` → `.checkbox`.
2. status 조건이 Complete 그룹 옵션을 제외하는 형태(`does_not_equal: <Complete 옵션>` 또는 To-do/In progress
   옵션만 `equals`) → `.status(done: Complete 그룹 첫 옵션, undo: To-do 그룹 첫 옵션)`.
3. 필터에서 못 찾으면: DB에 status가 하나뿐이면 2, checkbox가 하나뿐이면 1.
4. 그래도 모호하거나 없으면 `.readOnly`.
5. 제목 = title 속성. 날짜 = 정렬·필터에 쓰인 date 속성, 없으면 유일한 date 속성, 없으면 표시 안 함.

### 5.4 auth/ 토큰 교환 함수

| 경로 | 하는 일 |
|---|---|
| `GET /callback` | Notion이 `code`를 들고 돌아오는 리다이렉트 URI. code·state(거절이면 error)를 앱 주소 `notiontodo://oauth`로 넘긴다(302) — 인증 창이 가로채거나 브라우저가 앱을 연다 |
| `POST /token` | 앱이 `code` + PKCE `code_verifier`를 보냄 → `state`에 실었던 `code_challenge`와 대조 → secret으로 Notion 교환 → 토큰 반환 |
| `POST /refresh` | refresh 토큰 → secret으로 갱신 → 새 토큰 쌍 반환 |

- 앱↔함수 사이 PKCE: Notion OAuth엔 PKCE가 없지만 함수가 직접 확인해, 가로챈 `code`만으로는 교환할 수 없게 한다.
- 저장소·로그 없음. CORS 불필요(네이티브 앱 전용). 요청 크기·빈도 제한.
- 시크릿: `NOTION_OAUTH_CLIENT_ID` / `NOTION_OAUTH_CLIENT_SECRET` / `NOTION_OAUTH_REDIRECT_URI`.

### 5.5 앱 인텐트 목록

| 인텐트 | 쓰는 곳 |
|---|---|
| `SelectViewIntent` (`WidgetConfigurationIntent`, 파라미터 `NotionViewEntity`) | 위젯 편집 |
| `ToggleTodoIntent(pageId, viewId)` | 위젯·잠금화면 체크 |
| `AddMemoIntent(text, viewId?)` | Siri·단축어·앱 단축키 |
| `OpenComposerIntent` | 제어 위젯·위젯 `+` 버튼 |
| `RefreshIntent` | 위젯 오류 상태의 "다시 시도" |

`NotionViewEntity`의 `EntityQuery`는 캐시된 뷰 목록을 즉시 주고, 백그라운드로 갱신한다.
대시보드 뷰(`data_source_id == null`)와 form·chart·map 뷰는 목록에서 뺀다.

---

## 6. 품질

### 6.1 테스트

| 층 | 방법 |
|---|---|
| `ViewResolver`·쿼리 합성 | 단위 테스트. `scripts/probe-views.mjs`로 받은 실제 응답(.probe/)에서 ID를 가린 픽스처 사용 — UI 필터(`quick_filters`)·API 필터(`filter`)·`"me"`·`"today"`·status·checkbox 케이스 |
| NotionKit | `URLProtocol` 목으로 429·401·네트워크 오류 |
| 위젯 레이아웃 | `#Preview(as:)` 타임라인 프리뷰 + 스냅샷 테스트: 크기 × 렌더링 모드 3종 × 라이트/다크 × Dynamic Type(기본·XXXL) |
| 앱 UI | XCUITest 핵심 흐름 4개: 추가 → 체크 → 실행 취소 / 뷰 전환 / 오프라인 추가 후 복구 / 첫 실행 연결(토큰 → 추천 DB → 위젯 안내 → 목록, 단계별 스크린샷) |
| auth/ | 함수 단위 테스트(PKCE 대조 실패, 잘못된 code, refresh, 콜백이 앱 주소로 넘기기·거절 전달) |

### 6.2 실기기 확인 목록 (릴리스마다)

- [ ] 잠금 상태에서 잠금화면 위젯이 갱신된다 (AfterFirstUnlock)
- [ ] 잠금 상태에서 위젯 체크가 잠금 해제 없이 Notion에 반영된다 (4.5)
- [ ] 잠금 상태에서 체크 외 동작(추가 등)은 잠금 해제를 요구한다
- [ ] StandBy 주간·야간(적색) 표시
- [ ] 홈화면 tinted·clear 외형에서 체크 원·개수 강조
- [ ] 투명도 줄이기·대비 증가에서 입력 바와 툴바가 읽힌다
- [ ] VoiceOver: 행 = "치약 사기, 할 일, 체크 안 됨", 체크 버튼 동작 이름 "완료로 표시"
- [ ] Notion에서 연결 해제 → 앱·위젯이 "다시 로그인"으로 전환
- [ ] 새 Notion 계정: "Notion 연결하기" → 페이지 고르지 않고 "액세스 허용" → 시작 → "개인 페이지"에 메모 DB가 생기고 위젯에 뜬다
- [ ] Mac 기본 브라우저가 Safari일 때(인증 창)와 Chrome일 때(새 탭 → 앱 열기) 모두 연결된다. 취소하면 갇히지 않는다
- [ ] "오늘" 필터 뷰 위젯이 자정 직후 갱신된다 (4.4 자정 엔트리)

### 6.3 CI

GitHub Actions macOS 러너(공개 레포 무료)에서 `xcodebuild build test` — iOS 시뮬레이터·macOS 두 목적지.
서명 없이 빌드(`CODE_SIGNING_ALLOWED=NO`). `auth/`는 Node 테스트 잡 별도.

---

## 7. 마일스톤

각 단계는 끝 조건을 만족해야 다음으로 간다. 앞 단계는 internal integration 토큰 직접 입력으로 개발하고,
OAuth는 M6에서 붙인다(개발 속도 우선, 구조는 처음부터 `TokenStore` 경유).

| # | 내용 | 끝 조건 |
|---|---|---|
| **M0** 골격 | Xcode 프로젝트, 앱·위젯 타깃, 3개 패키지, xcconfig, CI | iOS·macOS 빈 앱과 빈 위젯이 CI에서 빌드 |
| **M1** NotionKit + TodoCore | 클라이언트, `ViewResolver`, 완료 추론, 캐시, 토큰 직접 입력 | 픽스처 단위 테스트 통과, 테스트 DB 두 개(체크박스·Status)에서 조회·체크 성공 |
| **M2** iPhone 앱 | 메인 목록, 유리 입력 바, 체크 손맛, 스와이프, 뷰 전환, 오프라인 대기열 | 기본 예시 DB로 하루 실사용 가능 |
| **M3** 홈화면 위젯 | 목록·개수 위젯, 뷰 선택 설정, 위젯 체크, 렌더링 모드 3종 | 홈화면에서 체크 → Notion 반영, tinted/clear 정상 |
| **M4** 잠금화면·StandBy·제어 | `accessory*`(잠금 중 체크 포함), StandBy, "메모 추가" 제어 위젯, Siri `AddMemoIntent` | 6.2 앞쪽 5개 항목 통과 |
| **M5** iPad·Mac | 분할 화면, 키보드, extra large·portrait 위젯, Mac 메뉴 막대 빠른 기록 | 세 기기에서 같은 DB로 동작 |
| **M6** OAuth·온보딩 | `auth/` 배포, 로그인, "새 할 일 메모 만들기", 위젯 안내 | 새 Notion 계정으로 설치~첫 위젯까지 2분 안 |
| **M7** 다듬기 | 접근성 전수, 애니메이션, 오류 상태, 현지화(한국어·영어) | 6.1·6.2 전부 통과 |
| **M8** 배포 | TestFlight 공개 베타 → (결정 시) App Store | 배포 채널 결정 기록 |

---

## 8. 리스크

| 리스크 | 영향 | 대응 |
|---|---|---|
| 위젯 갱신 예산이 예상보다 빡빡함 | 위젯 데이터가 오래됨 | 앱·인텐트 쪽 리로드로 보완, 마지막 갱신 시각 표시. 그래도 부족하면 2단계 푸시 |
| 잠금 중 체크가 실패 (토큰·파일 보호 등급) | 잠금화면 체크가 조용히 안 됨 | 4.5의 보호 등급 규칙 + 실패 시 대기열에 넣고 잠금 해제 후 재시도, 행에 대기 표시 |
| 사용자가 Status 옵션 이름을 바꿈 | 뷰 필터와 체크 대상 불일치 | 옵션은 이름이 아니라 ID로 다루고, 뷰 정의 갱신 시 재해석 |
| 뷰 필터에 해석 못 하는 조건(수식·롤업 등) | 완료 추론 실패 | 쿼리는 그대로 통과시키고(조회는 됨) 완료만 `.readOnly` |
| Notion API 버전 변경 | 응답 형식 변화 | `Notion-Version` 고정, 필터는 JSON 통과, 버전 올릴 때 probe 스크립트로 재검증 |
| 위젯이 자정을 넘겨도 갱신 전까지 어제의 "오늘"을 보여줌 | "오늘" 뷰 위젯이 잠시 밀림 | 날짜 필터 뷰는 다음 갱신 시각을 `min(20분 뒤, 다음 자정 직후)`로 둔다 (Notion은 "today"를 상대값으로 저장·재계산) |
| Liquid Glass 위 가독성 | 입력 바가 콘텐츠와 섞여 안 읽힘 | 표준 스크롤 가장자리 효과, 유리 아래 배경 단순화, 투명도 줄이기 점검 |
