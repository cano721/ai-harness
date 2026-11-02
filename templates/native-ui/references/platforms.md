# 플랫폼 참조

플랫폼마다 사용자가 기대하는 모양과, 검토할 때 앱을 띄우고 찍는 방법이다. 명령은 예시다 — 프로젝트의
빌드·실행 명령과 기기 이름은 `.ai-harness/docs/ui.md`가 정한다. 캡처는 저장소 밖(러너가 준 증거 경로, 없으면
임시 디렉터리)에 저장한다.

## iOS (SwiftUI·UIKit)

출처: Apple Human Interface Guidelines.

- **탭 바는 최상위 구역 2~5개.** 탭은 구역이지 행동이 아니다. 행동은 툴바·내비게이션 바 버튼으로 간다.
  계층은 내비게이션 스택, 독립된 짧은 작업은 시트.
- **가장자리 스와이프 뒤로 가기를 살려 둔다.** 내비게이션 바를 직접 만들거나 뒤로 버튼을 바꿔도 왼쪽 가장자리
  스와이프가 동작해야 한다.
- **시스템 컨트롤을 쓴다.** 스위치·세그먼트·스테퍼·날짜 선택기·액션 시트·알림·컨텍스트 메뉴·스와이프 동작을
  흉내 낸 커스텀 컨트롤로 바꾸지 않는다 — 접근성·글자 크기·다크 모드를 시스템이 이미 처리한다.
- **글자는 텍스트 스타일로.** Large Title부터 Caption까지의 Dynamic Type 스타일을 쓰고 pt를 고정하지 않는다.
- **색은 시스템 의미 색으로.** `label`·`secondaryLabel`·`systemBackground`·`separator`와 앱 tint. 다크 모드와
  대비 높이기 설정에 자동으로 맞춰진다.
- **터치 영역 44×44pt.**

띄우고 찍기:

```bash
xcrun simctl list devices booted                       # 켜진 시뮬레이터와 UDID
xcrun simctl io booted screenshot "$EVIDENCE/ios-default.png"
xcrun simctl ui booted appearance dark                  # 다크로 바꾼 뒤 다시 찍는다
xcrun simctl ui booted content_size extra-extra-extra-large   # 큰 글자 (접근성 크기는 accessibility-extra-large 등)
```

시뮬레이터가 여럿 켜져 있으면 `booted` 대신 UDID를 쓴다 — 기기 이름은 겹칠 수 있다. 앱이 iPad를 지원하면
iPhone과 iPad를 각각 찍는다. VoiceOver는 시뮬레이터에서 Accessibility Inspector로 이름·역할·상태를 확인하고,
실제 읽기 흐름은 실기기에서 확인한다(못 했으면 미검증으로 적는다).

## Android (Jetpack Compose·View)

출처: Material Design 3, Android 개발자 문서(edge-to-edge, predictive back, window size class).

- **최상위 구역 3~5개는 하단 내비게이션 바.** medium·expanded 폭(600dp 이상)에서는 내비게이션 레일(또는 넓은
  화면의 내비게이션 드로어)로 바뀐다. 2개 이하면 탭, 6개 이상이면 드로어를 검토한다.
- **predictive back을 막지 않는다.** 시스템 뒤로 가기는 `OnBackPressedDispatcher`·`BackHandler`로 받고, 뒤로
  가기 미리보기 애니메이션이 동작하게 한다(Android 13 이상에서 앱이 opt-in하면 동작하고, 15부터 시스템
  애니메이션이 기본으로 보인다). 뒤로 가기를
  삼켜 앱이 아무 반응도 하지 않게 만들지 않는다.
- **edge-to-edge와 인셋.** Android 15(targetSdk 35) 이상은 앱이 화면 끝까지 그려진다. 상태 바·내비게이션 바·
  디스플레이 컷아웃·키보드 인셋(`WindowInsets`)을 적용해 콘텐츠와 누르는 요소가 시스템 바 아래로 들어가지
  않게 한다.
- **터치 영역 48×48dp, 간격 8dp.** 글자는 `sp`, 나머지는 `dp`.
- **색은 Material 색 역할로.** `primary`·`onPrimary`·`surface`·`onSurface` 같은 역할을 쓰면 다크 테마와 동적
  색에 맞춰진다.

띄우고 찍기:

```bash
adb devices                                            # 켜진 에뮬레이터
adb exec-out screencap -p > "$EVIDENCE/android-default.png"
adb shell cmd uimode night yes                         # 다크
adb shell settings put system font_scale 1.3           # 큰 글자 (끝나면 1.0으로 되돌린다)
adb shell settings put global animator_duration_scale 0   # 애니메이션 삭제에 가까운 상태
```

에뮬레이터가 여럿이면 `adb -s <serial>`로 고른다. 바꾼 시스템 설정(다크·글꼴 크기·애니메이션 배율)은 검토가
끝나면 원래 값으로 되돌린다. TalkBack은 에뮬레이터에 설치돼 있지 않을 수 있다 — 없으면 Accessibility
Scanner·레이아웃 검사기로 이름·역할을 확인하고 읽기 흐름은 미검증으로 적는다.

## React Native·Expo

- 화면은 iOS 시뮬레이터와 Android 에뮬레이터에서 **각각** 본다. 한쪽 결과로 다른 쪽을 추정하지 않는다.
- `SafeAreaView`(또는 `react-native-safe-area-context`)로 안전 영역을, Android 하드웨어 뒤로 가기는 내비게이션
  라이브러리의 뒤로 처리로 받는다.
- `accessibilityLabel`·`accessibilityRole`·`accessibilityState`가 이름·역할·상태다. `AccessibilityInfo.
  isReduceMotionEnabled()`로 감소 모션을 읽는다.
- 같은 모양을 두 플랫폼에 쓸지, 플랫폼별 관용 표현(탭 바 위치, 뒤로 버튼 모양, 시스템 컨트롤)을 따를지는
  프로젝트 결정이다. 어느 쪽이든 각 OS의 안전 영역·뒤로 가기·글자 크기·스크린리더 보장은 유지한다.
- `react-native-web`으로 같은 코드를 웹에도 내면 웹 화면은 `ui-review`로 따로 검토한다.

## Flutter

- iOS·Android를 모두 내면 두 플랫폼에서 각각 본다. Material 위젯만 쓰더라도 iOS의 가장자리 스와이프 뒤로
  가기와 안전 영역(`SafeArea`)이 동작해야 한다.
- 이름·역할·상태는 `Semantics`, 상태 알림은 `SemanticsService.announce`. `MediaQuery.textScalerOf`·
  `MediaQuery.disableAnimationsOf`로 글자 크기와 감소 모션을 따른다. 고정 높이 안에 글자를 가두지 않는다.
- 크기 등급은 `MediaQuery.sizeOf` 폭으로 나누고, Material 3 기준(600dp·840dp)을 프로젝트가 다르게 정하지
  않았으면 그대로 쓴다.
- 캡처는 위 iOS·Android 명령을 그대로 쓴다. `flutter screenshot`도 된다. Flutter Web 캡처는 네이티브 증거가
  아니다.
