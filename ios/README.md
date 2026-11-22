# iOS 앱

SwiftUI, iOS 17 이상. 외부 의존성은 `supabase-swift` 하나입니다.

```
ios/
  project.yml            XcodeGen 프로젝트 정의 (앱 타깃 하나)
  App/                   앱 진입점, 진입 규칙, 탭 3개, 설정, Info.plist, 빌드 설정
  PonduKit/              Swift 패키지: 공용 코드와 기능 타깃
    Sources/PonduCore/       Backend, 모델, 공용 화면 부품, 도구, 가짜(Fake) 구현
    Sources/FeatureAuth/     가입(메일·코드·프로필), 프로필 수정
    Sources/FeatureSession/  (흐름 G) 세션
    Sources/FeatureRecord/   (흐름 G) 기록 탭
    Sources/FeatureTogether/ (흐름 H) 함께 탭
    Sources/FeatureToday/    (흐름 I) 오늘 탭
```

기능 타깃끼리는 서로 가져오지 않고 `PonduCore`에만 의존합니다.

## Mac에서 처음 여는 방법

필요한 것: Xcode 26 이상(supabase-swift 2.55 이상이 Swift 6.1 도구를 요구합니다. 더 낮은 Xcode는 `PonduKit/Package.swift`의 supabase-swift 버전을 낮춰야 하고, 그 경우 호출 이름을 다시 확인해야 합니다), [Homebrew](https://brew.sh).

```sh
# 1. XcodeGen 설치 (한 번만)
brew install xcodegen

# 2. 프로젝트 주소와 공개용 키 넣기
cd ios
cp App/Config/Secrets.example.xcconfig App/Config/Secrets.xcconfig
open -e App/Config/Secrets.xcconfig     # 아래 설명대로 두 값을 채운다

# 3. Xcode 프로젝트 만들기
xcodegen generate

# 4. 열기
open Pondu.xcodeproj
```

### 프로젝트 주소와 공개용 키를 넣는 위치

`ios/App/Config/Secrets.xcconfig` (저장소에 올라가지 않습니다)

```
SUPABASE_URL = https:/$()/abcdefghijkl.supabase.co
SUPABASE_ANON_KEY = eyJ...공개용 키...
```

- 값은 Supabase 대시보드의 Project Settings → API에 있는 **Project URL**과 **anon(public) key**입니다.
- xcconfig에서 `//`는 주석이라 주소는 반드시 `https:/$()/호스트`로 씁니다.
- **공개용 키만** 넣습니다. `service_role` 키, 메일 발송 서비스 키, AI 키는 앱에 들어가면 안 됩니다.
- 값이 비어 있으면 앱은 "설정이 필요해요" 안내만 보여 줍니다.
- 값은 빌드 때 `App/Info.plist`의 `PonduSupabaseURL`, `PonduSupabaseAnonKey`로 들어가고 `AppConfig`가 읽습니다.

### 번들 ID와 서명

`project.yml`의 `bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER`(지금은 `com.example.pondu` 자리표시)를 본인 소유 도메인으로 바꾸고, `DEVELOPMENT_TEAM`에 팀 ID를 넣은 뒤 `xcodegen generate`를 다시 실행합니다. 생성된 `Pondu.xcodeproj`는 저장소에 올리지 않습니다(`ios/.gitignore`).

### Supabase 쪽에서 맞춰 둘 것 (앱이 기대하는 값)

- 인증 → 이메일 로그인 방식은 **6자리 코드**. 이메일 템플릿(Magic Link/Confirm signup)에 `{{ .Token }}`이 보여야 합니다. 링크 방식은 쓰지 않습니다.
- 사진 저장소 버킷 이름은 `session-photos`(비공개)입니다. 다르면 `BackendConfig.photoBucket`을 바꿉니다.
- 가입 도메인 제한은 서버(흐름 A)가 합니다. 앱의 도메인 검사는 편의일 뿐입니다.

## 흐름 병합 후 처음 빌드하는 순서

다른 흐름의 폴더가 없으면 앱 타깃이 `import FeatureSession` 등을 풀지 못합니다. 흐름 브랜치를 모두 병합한 뒤 아래 순서로 확인합니다.

1. 흐름 F(이 브랜치) → G → H → I 순서로 병합합니다. 겹치는 파일은 없어야 합니다(소유 경로가 나뉘어 있습니다).
2. `PonduKit/Package.swift`는 `Sources/<타깃>` 폴더가 있는 기능 타깃만 선언하도록 되어 있어서, 병합이 끝나면 자동으로 `FeatureSession`, `FeatureRecord`, `FeatureTogether`, `FeatureToday`와 각 `Tests/<타깃>Tests`가 선언됩니다. 목록은 `featureTargets` 배열입니다.
3. 패키지만 먼저 확인합니다: `cd ios/PonduKit && xcodebuild -scheme PonduKit-Package -destination 'platform=iOS Simulator,name=iPhone 16' build`
4. 패키지 시험: 같은 명령에서 `build`를 `test`로 바꿉니다. (`PonduCoreTests`, `FeatureAuthTests`는 이 브랜치에 있습니다.)
5. 앱: `cd ios && xcodegen generate && xcodebuild -project Pondu.xcodeproj -scheme Pondu -destination 'platform=iOS Simulator,name=iPhone 16' build`
6. 실물 기기에서 M0 명세 5.2절을 확인합니다.

## 앱 껍데기와 기능 타깃의 연결

| 위치 | 하는 일 |
|---|---|
| `App/PonduApp.swift` | 진입점. 설정이 없으면 안내 화면, 있으면 `RootView` |
| `App/AppEnvironment.swift` | `SupabaseBackend`, `SessionController`, `ImageLoader`, `AuthStore`, `AppDependencies` 조립 |
| `App/RootView.swift` | 진입 규칙(메일 입력 / 프로필 만들기 / 홈). 홈은 `SessionHostView(controller:) { MainTabView }` |
| `App/MainTabView.swift` | 탭 3개(오늘 `TodayRootView`, 함께 `TogetherRootView`, 기록 `RecordRootView`)와 설정 진입점 |
| `App/SettingsView.swift` | 내 프로필 보기·수정(`ProfileEditView`), 로그아웃 |
| `App/AppDelegate.swift` | 백그라운드 사진 올리기가 끝났을 때 앱이 깨어나는 경로 |

## 기능 흐름이 알아 둘 것

- 서버 호출은 `deps.backend`로만 합니다. 시험에서는 `PonduCore`의 `FakeBackend`, `FakeAuthService`, `FakeSessionController`를 씁니다.
- 로그아웃하면 `Notification.Name.ponduDidSignOut`가 옵니다. 각 기능은 자기 기기 저장분(SwiftData, 캐시 파일)과 예약한 로컬 알림을 지웁니다. 이미지 캐시와 내 프로필 캐시는 F가 지웁니다.
- SwiftData를 쓰는 기능은 저장소 이름을 직접 붙입니다(`ModelConfiguration("pondu-record", ...)`처럼). 이름 없는 기본 저장소는 서로 부딪힙니다. F의 프로필 저장소 이름은 `pondu-profile`입니다.
- 서버가 주는 시각은 `PonduJSON.makeDecoder()`가 읽습니다. 분야 이름을 키로 쓰는 사전(`estimate_factors`, `by_category`)은 `[String: ...]`로 받고 키는 `Category.rawValue`(`venture_research_intern` 포함)로 조회합니다.
- 사진 올리기는 `deps.backend.upload(path:fileURL:contentType:)`입니다. 파일은 전송이 끝날 때까지 지우지 마세요(앱 지원 폴더 권장). 앱이 종료됐다 다시 뜨면 결과 알림이 오지 않으므로 대기 중인 사진은 앱 시작 때 다시 올립니다(같은 경로 덮어쓰기라 안전합니다).
- 설정 화면은 앱 껍데기가 왼쪽 위 톱니 버튼으로 엽니다. 탭 화면이 자기 툴바에 두고 싶으면 `SettingsButton()`을 쓰면 됩니다(`\.showSettings` 환경값).
