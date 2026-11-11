# 개인정보 처리방침 · Privacy Policy

시행일 / Effective: 2026-11-11 · 앱 / App: **Todo Widget for Notion** (할 일 위젯)

## 한국어

**요약: 개발자는 사용자의 데이터를 수집하지 않습니다.**

- **메모는 기기와 Notion 사이에서만 오갑니다.** 앱과 위젯은 사용자가 연결한 Notion 워크스페이스의 데이터베이스를
  Notion API로 직접 읽고 씁니다. 개발자의 서버를 거치지 않습니다.
- **로그인.** "Notion으로 로그인"은 Notion의 로그인 화면에서 이뤄집니다. 로그인 뒤 받는 접근 토큰은 기기의
  Keychain에만 저장되고, 앱과 위젯이 공유합니다. 토큰을 기기 밖으로 내보내지 않습니다.
- **로그인 중계 함수.** Notion이 요구하는 비밀 키를 앱에 넣지 않으려고, 로그인 때 인증 코드를 토큰으로 바꾸는 작은
  함수(`notion-todo-auth.vercel.app`)를 한 번 거칩니다. 이 함수는 코드를 Notion에 전달하고 결과를 앱에 돌려줄 뿐
  토큰·메모·사용자 정보를 저장하거나 기록하지 않습니다. (호스팅 업체가 기본 접속 기록을 남길 수 있습니다.)
- **기기에만 저장하는 것.** 마지막으로 받아 온 메모 목록(캐시), 앱에서 정한 순서와 섹션, 설정, 아직 보내지 못한
  변경. 로그아웃하면 지워집니다.
- **분석·광고·추적 없음.** 분석 도구, 광고 SDK, 추적 기능이 없고 사용자를 식별하는 정보를 모으지 않습니다.
- **잠금 화면 카드(실시간 현황).** 메모 제목이 잠금 화면에 보입니다. 기기를 잠가 둔 상태에서도 보이므로 원하지
  않으면 설정에서 끄세요.
- **Notion.** Notion에 저장된 데이터에는 [Notion의 개인정보 처리방침](https://www.notion.com/notion/privacy)이
  적용됩니다. Notion 설정 ▸ 연결에서 이 앱의 접근을 언제든 해제할 수 있습니다.
- **어린이.** 별도 계정이나 개인정보를 받지 않습니다.

문의: [GitHub 이슈](https://github.com/shw1606/notion-todo/issues) · 소스 코드는 공개되어 있어 위 내용을 직접 확인할 수 있습니다.

## English

**In short: the developer does not collect your data.**

- **Your memos travel only between your device and Notion.** The app and widgets read and write the Notion
  databases you connect, directly through the Notion API. Nothing passes through the developer's servers.
- **Sign-in.** "Sign in with Notion" happens on Notion's own sign-in page. The access token you receive is stored
  only in the device Keychain (shared between the app and its widgets) and never leaves the device.
- **Sign-in relay function.** To keep Notion's client secret out of the app, one small function
  (`notion-todo-auth.vercel.app`) exchanges the authorization code for a token during sign-in. It forwards the code
  to Notion and returns the result to the app; it does not store or log tokens, memos or user information. (The
  hosting provider may keep standard connection logs.)
- **Stored only on your device:** the last downloaded memo list (cache), your custom order and sections, settings,
  and changes not yet sent. Signing out removes them.
- **No analytics, ads or tracking.** There are no analytics tools, ad SDKs or trackers, and no identifying data is
  collected.
- **Lock Screen card (Live Activity).** Memo titles are shown on the Lock Screen, visible while the device is
  locked. Turn it off in Settings if you don't want that.
- **Notion.** Data stored in Notion is covered by [Notion's privacy policy](https://www.notion.com/notion/privacy).
  You can revoke this app's access at any time in Notion under Settings ▸ Connections.
- **Children.** The app creates no accounts and collects no personal information.

Contact: [GitHub issues](https://github.com/shw1606/notion-todo/issues). The source code is public, so you can verify
all of the above.
