# 배포 절차 (PLAN 7장 M8)

Apple Developer Program 계정과 Notion·Cloudflare 계정이 필요하다. 코드 쪽 준비는 끝나 있고, 아래는 계정이
필요한 단계만 모은 것이다.

## 1. 로그인 함수 배포

[auth/README.md](../auth/README.md)대로 Notion public integration을 만들고 Cloudflare Workers에 배포한다.
integration 이름(`Notion Todo`)과 아이콘을 채운다 — 연결할 때 Notion 동의 화면에 보인다.
배포 후 `https://<auth 호스트>/callback?code=x&state=y`가 `notiontodo://oauth?code=x&state=y`로 302를 돌려주는지 확인한다.

## 2. 서명 설정

1. `apps/Config/Local.xcconfig.example` → `apps/Config/Local.xcconfig` 복사 후 채운다
   (`DEVELOPMENT_TEAM`, `BUNDLE_ID_PREFIX`, `NT_OAUTH_CLIENT_ID`, `NT_AUTH_BASE_URL`).
2. Apple Developer 사이트에서 식별자 두 개를 만든다 — 앱 `<접두사>.notiontodo`, 위젯 `<접두사>.notiontodo.widgets`.
   두 식별자 모두 **App Groups**(iOS `group.<접두사>.notiontodo`, Mac은 팀 ID 접두사 그룹)와 **Keychain Sharing**을
   켠다. 로그인 콜백은 앱 주소(`notiontodo://`)라 Associated Domains는 필요 없다. Xcode 자동 서명을 쓰면 대부분 자동으로 된다.
3. `apps/NotionTodo.xcodeproj`를 열어 iPhone·Mac 각각 실행해 본다.

## 3. 실기기 확인 (PLAN 6.2 — 릴리스마다)

- [ ] 잠금 상태에서 잠금화면 위젯이 갱신된다
- [ ] 잠금 상태에서 위젯 체크가 잠금 해제 없이 Notion에 반영된다
- [ ] 잠금 상태에서 체크 외 동작(추가 등)은 잠금 해제를 요구한다
- [ ] StandBy 주간·야간(적색) 표시
- [ ] 홈 화면 tinted·clear 외형에서 체크 원·개수 강조
- [ ] 투명도 줄이기·대비 증가에서 입력 바와 툴바가 읽힌다
- [ ] VoiceOver: 행 = "치약 사기, 체크 안 됨", 체크 버튼 힌트 "완료로 표시"
- [ ] Notion에서 연결 해제 → 앱·위젯이 "다시 로그인"으로 바뀐다
- [ ] 새 Notion 계정: "Notion 연결하기" → 페이지 고르지 않고 "액세스 허용" → 시작 → "개인 페이지"에 메모 DB가 생기고 위젯에 뜬다
- [ ] Mac 기본 브라우저가 Safari일 때(인증 창)와 Chrome일 때(새 탭 → 앱 열기) 모두 연결된다. 취소하면 갇히지 않는다
- [ ] "오늘" 필터 뷰 위젯이 자정 직후 갱신된다
- [ ] 제어 센터 "메모 추가" → 앱이 입력 바에 커서를 둔 채 열린다
- [ ] Siri "Notion Todo에 메모 추가" → 앱을 열지 않고 추가된다
- [ ] Mac 메뉴 막대에서 추가·체크, 창 닫은 뒤에도 아이콘 유지

## 4. TestFlight

1. Xcode → Product → Archive (iOS, macOS 각각). 버전은 `project.yml`의 `MARKETING_VERSION`.
2. App Store Connect에 앱을 만들고 업로드한다.
3. **앱 개인정보**: "데이터를 수집하지 않음" — 메모는 기기와 사용자의 Notion 사이에서만 오가고, 토큰 교환 함수는
   아무것도 저장하지 않는다. 분석·추적 SDK 없음.
4. **수출 규정**: 표준 HTTPS만 사용 → `ITSAppUsesNonExemptEncryption = NO`(Info.plist에 이미 들어 있음).
5. **심사 메모**: 테스트용 Notion 계정과 공유된 예시 DB를 적어 둔다 ("Notion으로 로그인" 후 페이지 선택 필요).
6. 공개 베타 링크를 README에 추가한다.

## 5. App Store (결정 시)

배포 채널은 README "열린 결정"에서 정한다. App Store로 갈 경우 스크린샷은 위젯 스냅샷 테스트 산출물
(`WidgetSnapshots` 스킴)과 시뮬레이터 캡처를 바탕으로 만든다.
