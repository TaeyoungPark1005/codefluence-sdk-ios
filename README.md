# Codefluence iOS SDK

The SDK validates copied referral URLs with `detectPatterns(for: [.probableWebURL])`; use `restoreReferralTokenAsync()` or `handleOpenURL(_:)` for `https://HOST/t/{token}` links. `purchaseAccountToken()` returns this install's stable UUID; pass it as `appAccountToken` when starting a purchase. Inject App Attest through `AttestationProvider` when calling `heartbeat` (one aggregate request per day).

iOS 16+, Swift tools 5.9의 Swift Package입니다(공개 저장소 `https://github.com/TaeyoungPark1005/codefluence-sdk-ios`, 설치는 아래 「설치」). 패키지에는 `UserDefaults` 접근 사유와 수집 데이터 4종(구매 내역·사용자 ID·제품 상호작용·광고 데이터)을 선언하는 `PrivacyInfo.xcprivacy`가 포함됩니다. 항목별 App Store·Google Play 표기 안내는 서버의 `/docs#store-privacy`에 있습니다. 권장 흐름은 소개 토큰 복원 후 확인창 없이 `/track/confirm`을 호출하는 자동 귀속이며, 소개 코드 입력 UI는 없습니다. 기존 명시적 동의가 필요한 호스트는 `showConfirmationIfNeeded`를 사용할 수 있습니다.

## PrivacyInfo와 Required Reason API

`PrivacyInfo.xcprivacy`의 Required Reason API 선언은 `NSPrivacyAccessedAPICategoryUserDefaults`의 사유 `CA92.1`(앱 그룹 등 외부와 공유하지 않는, 앱 자신의 `UserDefaults` 접근)만 선언합니다. SDK는 소개 결정·대기 큐·심장박동 날짜를 자신의 `UserDefaults` suite에만 저장하므로 이 사유가 정확합니다.

**UIPasteboard Required Reason API 대상 여부 — 대상 아님.** Apple의 Required Reason API는 다섯 범주(File timestamp, System boot time, Disk space, Active keyboard, User defaults)로 고정되어 있고 `UIPasteboard`는 어느 범주에도 포함되지 않습니다. 따라서 `NSPrivacyAccessedAPITypes`에 pasteboard 선언을 추가하지 않습니다. 클립보드는 별도의 프라이버시 메커니즘(시스템 붙여넣기 알림)으로 다루며, SDK는 값을 읽기 전에 `detectPatterns(for: [.probableWebURL])`로 존재만 확인해 일반 설치자에게 붙여넣기 알림을 띄우지 않습니다.

근거(2026-10-28 확인):

- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api) — 범주별 API 목록은 하위 문서에서 열거하며 pasteboard 범주는 없음.
- [NSPrivacyAccessedAPIType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) — 유효한 `NSPrivacyAccessedAPIType` 값은 위 다섯 범주의 문자열(예: `NSPrivacyAccessedAPICategoryUserDefaults`)로 한정.
- [UIPasteboard detectPatterns](https://developer.apple.com/documentation/uikit/uipasteboard/detectpatterns(for:completionhandler:)-23vwn) — 내용 접근 없이 패턴 존재만 확인하므로 붙여넣기 알림을 유발하지 않음.

Apple이 목록을 갱신해 pasteboard가 Required Reason 범주로 편입되면 그 시점에 해당 `NSPrivacyAccessedAPIType`와 승인 사유를 추가해야 합니다. 현재 기준으로는 추가하지 않습니다.

## 빠른 시작 (권장)

```swift
import Codefluence

// 앱 시작(구매 SDK 설정 뒤). 사용자 ID를 아직 모르면 nil을 돌려주면 됩니다.
Codefluence.start(publicKey: "pk_...", apiHost: URL(string: "https://YOUR_CODEFLUENCE_HOST")!, appUserId: { stableAppUserId })

// 들어오는 모든 URL을 넘깁니다. 소개 링크일 때만 true.
.onOpenURL { Codefluence.shared.handle(url: $0) }

Codefluence.shared.resume()            // 사용자 ID가 뒤늦게 정해졌을 때
Codefluence.shared.purchaseCompleted() // 결제가 끝났을 때(어떤 구매 SDK든)
```

`start`는 `configure`를 부르고, 딥링크가 시작이나 사용자 ID보다 먼저·나중에 와도 토큰을 보관했다가 ID가 정해지면 확인합니다. 시작 직후 소개 링크가 없다는 판단(귀속 없음 확정)은 1초 유예 뒤에 하므로 콜드 스타트 딥링크가 사라지지 않습니다. 앱이 전면으로 올 때마다 `resume()`을 자동으로 부릅니다. `purchaseCompleted()`는 소개로 온 설치에서만 결제를 보고합니다. 앱의 URL 스킴(URL Types)은 호스트 앱이 등록하고 대시보드 제품 화면의 「앱 열기 스킴」에도 같은 값을 저장하세요. 아래 개별 호출(`configure`, `autoConfirmIfAvailable`, `reportPurchases` 등)은 세밀한 제어가 필요할 때만 씁니다.

## 설치

Xcode: **File → Add Package Dependencies**에 아래 주소를 입력하고 앱 타깃에 `Codefluence` 라이브러리를 연결합니다.

```
https://github.com/TaeyoungPark1005/codefluence-sdk-ios
```

Swift Package 매니페스트에서는:

```swift
dependencies: [
    .package(url: "https://github.com/TaeyoungPark1005/codefluence-sdk-ios", from: "0.2.1")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "Codefluence", package: "codefluence-sdk-ios")
    ])
]
```

## 출시 전 설치 점검

```swift
#if DEBUG
Codefluence.shared.validate(urlScheme: "myapp") { checks in
    // 콘솔에 [Codefluence] ✓/✗ 항목: 안내가 찍힙니다.
}
#endif
```

점검 항목: ① 설정(pk_ 키 모양·서버 주소, 비밀 키 sk_가 들어 있으면 실패) ② 서버와 키(실제로 heartbeat를 보내 키가 받아들여지는지, 플랫폼이 맞는지, 서버에 닿는지) ③ 빌드(안내 항목, 0.2.1) ④ URL 스킴(`urlScheme`을 넘겼을 때 Info.plist URL Types에 등록돼 있는지). 실패하면 무엇을 고쳐야 하는지가 `hint`에 나옵니다. 통과하면 서버에 첫 신호가 도착해 대시보드 제품 연동 화면의 「앱 SDK 신호」가 바로 바뀝니다. `start`도 하루에 한 번 같은 신호를 자동으로 보냅니다. 토큰·키 값은 출력하지 않습니다. 디버그 빌드에서만 호출하세요.

**개발 빌드 표시(0.2.1).** SDK는 모든 서버 요청에 `build`(`"debug"` 또는 `"release"`)를 싣습니다. 앱이 Debug 구성(`DEBUG`)이거나 시뮬레이터에서 돌면 `"debug"`입니다(`Codefluence.build`). 서버는 개발 빌드의 heartbeat를 대시보드에 「개발 빌드에서 확인됨」으로만 보여 주고 SDK 무결성 판정·confirm 비율에서 빼며, 확인·재열기·활동 신호·광고 수익·결제 보고는 sandbox로 기록해 보상과 집계에서 뺍니다. 그래서 디버그 빌드로 `validate`를 돌려도 운영 숫자가 오염되지 않습니다. 출시(Release) 빌드는 지금처럼 집계됩니다. TestFlight·샌드박스 결제는 이 값과 관계없이 스토어 응답으로 sandbox가 됩니다.

Development builds (0.2.1): every request carries `build` (`"debug"` for the Debug configuration or the simulator). The server shows those heartbeats as "seen in a development build" and keeps them, and the confirmations, signals and purchases they send, out of production totals and rewards (sandbox).

## 설정과 첫 화면 확인

```swift
import Codefluence
import UIKit

Codefluence.configure(
    publicKey: "pk_...",
    apiHost: URL(string: "https://YOUR_CODEFLUENCE_HOST")!
)

// 앱 시작 또는 딥링크 수신 후 호출합니다.
// 앱이 쓰는 안정적인 사용자 ID를 사용합니다.
Codefluence.shared.autoConfirmIfAvailable(
    appUserId: stableAppUserId
) { result in
    DispatchQueue.main.async {
        switch result {
        case .success(let leadId):
            // nil은 토큰 없음 또는 일반 시작, 문자열은 서버 leadId입니다.
            print(leadId == nil ? "일반 시작" : "소개 연결 완료")
        case .failure:
            // 토큰·고객 ID·비밀 값은 로그에 남기지 않습니다.
            print("소개 자동 연결 요청 실패")
        }
    }
}
```

`YOUR_CODEFLUENCE_HOST`를 실제 서버 주소로 바꿉니다. `configure`의 `apiHost`는 경로·query·fragment·사용자정보가 없는 명시적인 HTTP(S) origin과 호스트가 필수이며 기본 서버 주소는 없습니다. 공개 키는 `pk_`로 시작해야 하며, 공개 키 또는 host가 비어 있거나 잘못된 scheme이면 확인·재시도가 설정 오류로 끝나고 네트워크 요청을 만들지 않습니다. `sk_live_`·`sk_test_`는 앱에 넣지 않습니다. 명시적으로 동의한 미완료 토큰·고객 ID는 보존됩니다. 시뮬레이터의 로컬 HTTP 실험에는 호스트 앱의 개발용 ATS 설정이 별도로 필요하며 운영에는 HTTPS를 사용합니다.

- 복원 순서: 저장된 `clickToken` → iOS 클립보드. `autoConfirmIfAvailable`는 토큰이 있으면 확인창 없이 귀속하고, 없으면 귀속 없이 `success(nil)`을 반환합니다. 이후 토큰이 생겨도 같은 설치에서 새 귀속을 만들지 않습니다. 이미 완료된 lead는 다시 반환할 수 있습니다.
- 명시적 동의가 필요한 경우에만 `showConfirmationIfNeeded(from:appUserId:clickToken:completion:)`을 사용합니다. 이 경로는 기존처럼 예를 눌렀을 때만 확인 요청을 보냅니다.
- 확인창은 기기의 첫 선호 언어가 `ko`이면 한국어, 그 외에는 영어입니다. 영어 문구는 **Start with this referral? / Use this referral link to attribute your purchases. / Yes / No**입니다.
- **아니오:** 결정을 저장하고 `success(nil)`, 서버 요청 없음.
- **예:** 동의와 미완료 토큰·고객 ID를 저장한 뒤 공개 키로 서버 요청. callback은 메인 스레드로 전달합니다.
- iOS의 붙여넣기 권한이나 클립보드 접근 결과는 실제 기기에서 확인해야 합니다. 설치 후 토큰이 항상 복원된다는 보장은 없습니다.

## URL scheme 경로는 호스트 앱에서 연결

앱의 URL Types에 예를 들어 `myapp`을 등록합니다. SDK는 scheme 등록·URL 수신을 자동 처리하지 않습니다. 호스트 앱이 `myapp://referral?cf_click_token=...`을 받아 `autoConfirmIfAvailable`에 전달합니다.

```swift
// 앱의 onOpenURL 또는 SceneDelegate에서 얻은 URL을 전달합니다.
@MainActor
func handleReferralURL(_ url: URL, presenter: UIViewController, appUserId: String) {
    guard url.scheme == "myapp", url.host == "referral",
          let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "cf_click_token" })?.value,
          !token.isEmpty else { return }
    Codefluence.shared.autoConfirmIfAvailable(
        appUserId: appUserId, clickToken: token
    ) { result in
        // nil은 토큰 없음, leadId는 자동 귀속 완료. callback은 메인 스레드입니다.
    }
}
```

자동 귀속 또는 예·아니오 결정과 미완료 요청은 SDK가 저장합니다. 토큰을 입력받거나 임의로 만들어 보내지 않습니다. Codefluence 서버가 HMAC 서명·제품·유효기간과 실제 클릭을 검증합니다. 호스트 자체 확인 UI를 쓴다면 명시적인 예 이후에만 공개 `confirm`을 호출하며 저장된 아니오를 우회할 수 없습니다.

## 키, 고객 ID, 결제

앱에는 제품의 `pk_...`만 넣고 `sk_live`·`sk_test`는 제품 서버에만 둡니다. `pk`는 환경을 강제하지 않으며 `/track/confirm`은 서명된 클릭의 sandbox를 계승합니다. 구매 기록은 스토어 서버 알림(App Store·Google Play) 또는 제품 서버의 sale으로 전달하며, 앱 구매 성공 콜백 자체로 sale을 만들지 않습니다.

확인 요청의 `appUserId`는 앱이 쓰는 안정적인 사용자 ID로 유지합니다. 로그인·계정 전환 후에도 같은 기준을 쓰고 임의 이메일·기기 ID를 대신 쓰지 않습니다. SANDBOX 거래는 운영 청구·지급에서 제외됩니다.

## 자동 재시도와 멱등 (A3)

자동 귀속과 기본 시트는 네트워크 요청 전에 결정을 저장합니다. 동의된(자동 귀속 포함) 미완료 confirm은 영속 큐에 남아, **앱 재실행(`configure` 호출) 시점**과 **네트워크 복구(`NWPathMonitor`)** 때 지수 backoff로 자동 재전송됩니다. backoff는 기본 2초 시작·2배·상한 1시간·full jitter이며 최대 시도 횟수 상한(기본 10회)에서 멈춥니다. 요청마다 첫 큐잉 때 생성·저장한 동일 `Idempotency-Key` 헤더를 보내 서버가 `/track/confirm`에서 멱등 처리합니다.

```swift
Codefluence.shared.retryPendingConfirmation { result in
    // 메인 스레드 callback. 수동 즉시 재시도이며 backoff 상태를 초기화합니다.
}
```

재시도하지 않는 경우: 사용자가 **거절**한 경우, 이미 **완료(confirmed)**된 경우, 서버가 돌려준 **영구 오류(400/401/403/404/409/422)**. 이때 큐를 비우고 더 보내지 않습니다. **408/429/5xx·네트워크 오류**만 backoff로 재시도합니다. 요청 timeout은 5초이며 유효한 비어 있지 않은 leadId를 받은 뒤 완료로 저장합니다. 진행 중 요청과 표시 중 확인 창은 중복 시작하지 않고, `confirm`을 다른 토큰·고객 ID로 바꿔 동의한 대기 요청을 덮어쓸 수 없습니다. 완료 뒤 같은 고객의 직접 `confirm`은 저장된 leadId를 반환합니다. 이전 버전의 결정에는 예·아니오 구분이 없으므로 동의 증거 없이 retry 대상으로 승격하지 않습니다.

설치 복원 보장, 스토어 구매 연결, 실제 확인 시트는 별도 기기 QA가 필요합니다. 전체 서버·웹훅 예제는 실행 중인 Codefluence의 `/docs`에 있습니다.

## 구조화 에러 (B6)

실패 결과는 공개 `enum CodefluenceError: Error`입니다. 기존 숫자 코드는 `code` 속성으로 유지하고 `CustomNSError`로 `Codefluence` 도메인·같은 code에 브리지하므로, 기존 `(error as NSError).code` 검사와 새 `switch` 분기를 모두 쓸 수 있습니다. `isRetryable`은 호스트가 재시도 가능 여부를 판단할 때 씁니다(현재 `requestFailed`만 `true`).

| code | case | 의미 | 재시도 |
| --- | --- | --- | --- |
| 1 | `requestFailed(message:)` | 네트워크/HTTP 요청 실패 또는 응답 무효 | 가능 |
| 2 | `missingReferralInput` | 토큰·고객 ID 누락 | 불가 |
| 3 | `declined` | 저장된 "아니오" | 불가 |
| 4 | `attributionForDifferentCustomer` | 다른 고객의 귀속 | 불가 |
| 5 | `retryIdentityMismatch` | 재시도가 토큰·고객 ID를 바꿈 | 불가 |
| 6 | `noPendingConfirmation` | 재시도할 대기 요청 없음 | 불가 |
| 7 | `requestInProgress` | 요청 진행 중 | 불가 |
| 8 | `alreadyPresenting` | 확인창/귀속 이미 진행 | 불가 |
| 9 | `presenterOrCustomerRequired` | presenter/고객 ID 필요 | 불가 |
| 10 | `decisionAlreadyMade` | 이미 결정됨 | 불가 |
| 11 | `notConfigured(message:)` | 미설정(pk_ 키/apiHost) | 불가 |
| 12 | `noSubscriptionReference` | 저장된 lead/purchaseAccountToken 없음 | 불가 |
| 13 | `subscriptionNotFound` | 서버에 구독 기록 없음(404) | 불가 |
| 14 | `confirmationRejected` | 서버가 같은 고객의 다른 설치 확인을 거절(409). 재설치 뒤 Apple 앱 거래 ID로 증명되면 자동 복구되고, 그렇지 않으면 이 오류 | 불가 |

```swift
switch result {
case .success(let leadId): /* ... */
case .failure(let error):
    if let e = error as? CodefluenceError, e.isRetryable { /* 나중에 다시 */ }
}
```

## 구독 상태 읽기 (C3, 읽기 전용)

`subscriptionStatus(completion:)`는 서버가 어댑터 이벤트를 정규화한 구독 상태를 읽습니다. **읽기 전용 view이며 entitlement 판정이 아닙니다.** 유료 기능 접근 제어에는 사용하지 말고, 접근 권한은 결제 제공자의 entitlement/영수증 검사로 판단하세요.

```swift
Codefluence.shared.subscriptionStatus { result in
    switch result {
    case .success(let status):
        // status.state: none|active|grace|cancelled|expired|refunded
        // status.sandbox, status.updatedAt, status.events
        break
    case .failure(let error):
        // noSubscriptionReference(저장값 없음) 또는 subscriptionNotFound(404)
        break
    }
}
```

`/track/confirm`에서 저장한 `leadId`와 `purchaseAccountToken`으로 `POST {apiHost}/track/subscription`(`Authorization: Bearer pk_...`)을 호출합니다. 저장값이 없으면 `noSubscriptionReference`, 서버 404는 `subscriptionNotFound`를 반환합니다. 알 수 없는 event type은 `kind`가 `nil`이고 `rawType`에 원문을 보존합니다.

## 활동 신호와 `trackMilestone` (0.2.0)

개발자 서버가 없는 앱의 활성 사용자 보상을 위해 SDK가 확인된 소개 설치에 묶인 **하루 한 번의 활동 신호**를 App Attest 증명과 함께 보냅니다(설계 `docs/superpowers/specs/2026-11-10-activation-reward-design.md` §4.3, 서버 계약 `docs/SPEC.md` §29).

- **서버 플래그가 꺼져 있으면 아무것도 보내지 않습니다.** 먼저 `GET /track/signal-config`에 공개 키만 보내 기능 상태를 묻고(6시간 캐시), 켜져 있고 이 설치가 소개로 온 활성 보상 설치일 때만 challenge → 증명 → 신호 순서로 보냅니다. 앱은 `start`/`resume()` 때 자동으로 시도합니다.
- 시뮬레이터와 App Attest를 지원하지 않는 환경(대부분의 앱 확장 포함)에서는 보내지 않습니다. 증명 실패, 네트워크 오류, 서버 거절은 모두 `.skipped(reason:)`로 끝나며 예외나 크래시를 내지 않습니다. 하루 시도는 3회로 제한합니다.
- `Codefluence.shared.trackMilestone("onboarded")`: 캠페인이 정한 완료 행동이 있을 때 그 이름을 서명된 신호에 실어 보냅니다. 이름은 영문자·숫자·`_ . -` 40자 이하이고 그 밖의 값은 무시합니다.
- **앱에서 할 일:** Signing & Capabilities에 App Attest를 추가하고(entitlement `com.apple.developer.devicecheck.appattest-environment`, 개발 빌드는 `development`, 배포는 `production`) 제품 설정에 Apple 팀 ID를 입력합니다. 광고 ID와 ATT는 쓰지 않습니다.
- PrivacyInfo.xcprivacy에 광고 데이터(`NSPrivacyCollectedDataTypeAdvertisingData`, 광고 수익 보고의 금액·통화·노출 수, 연결됨, 추적 아님, 개발자 광고)와 제품 상호작용(`NSPrivacyCollectedDataTypeProductInteraction`, 연결됨, 추적 아님, 개발자 광고)을 선언했습니다. App Store Connect의 앱 개인정보에도 같은 항목을 반영하세요(항목별 표는 `/docs#store-privacy`). 근거: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files/describing-data-use-in-privacy-manifests
- App Attest 공식 문서: https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity

## 광고 수익 보고 (`reportAdRevenue`, 0.2.0)

광고 수익 보상 캠페인을 쓰는 앱은 AdMob의 노출 단위 수익(paid event) 값을 SDK로 넘깁니다. SDK가 기기에서 합산해 **한 시간에 한 번 이하**로 묶어 보냅니다(설계 `docs/SPEC.md` §26, 서버 계약 §26.2).

```swift
// 광고 형식마다 광고 객체를 받자마자, 보여 주기 전에 처리기를 붙입니다.
ad.paidEventHandler = { adValue in
    Codefluence.shared.reportAdRevenue(
        value: adValue.value as Decimal,
        currencyCode: adValue.currencyCode,
        precision: adValue.precision == .precise ? .precise : adValue.precision == .estimated ? .estimated : adValue.precision == .publisherProvided ? .publisherProvided : .unknown)
}
```

- `precision: .unknown`(테스트 광고 등)은 노출 수만 세고 수익은 더하지 않습니다. 통화는 KRW·USD·JPY·EUR만 받고 그 밖의 값과 음수는 무시합니다.
- **서버가 광고 수익을 켜기 전에는 아무것도 보내지 않습니다.** 먼저 `GET /track/signal-config`에 공개 키만 보내 `adRevenue: true`인지 묻고(6시간 캐시), 아니면 값은 기기에 남습니다.
- 소개로 온 설치는 App Attest 증명과 함께 보내며 서버가 서명한 요청 원문(`challenge\n통화,값,노출,미확정노출`)을 다시 만들어 확인합니다. 증명이 통과한 값만 크리에이터 몫 계산에 쓰입니다. 소개 기간이 끝났거나 증명을 쓸 수 없는 환경에서는 **식별자 없이 합계만** 보내며 이 값은 지급 근거가 아니라 분모(앱 전체 SDK 합계)에만 쓰입니다.
- 보내는 것은 금액(마이크로 단위)·통화·노출 수뿐입니다. 광고 ID(IDFA)와 ATT는 쓰지 않습니다. 429는 한 시간 쉬었다가 다시 보내고, 실패한 묶음은 기기에 남겨 다음에 보냅니다.
- 호출은 AdMob 처리기 안에서 바로 하세요. SDK는 앱 시작 때도 남은 값을 보냅니다. 예외나 크래시를 내지 않습니다.
- 공식 문서: https://developers.google.com/admob/ios/impression-level-ad-revenue (Google Mobile Ads SDK 9.10.0 이상, AdMob 화면에서 노출 단위 수익 켜기 필요)

## 로컬 검증

```sh
swift test
xcodebuild -scheme Codefluence -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/codefluence-sdk-ios-build CODE_SIGNING_ALLOWED=NO build
```

단위 테스트는 별도 UserDefaults suite와 모의 URLSession transport를 사용합니다. 토큰 없는 소프트 상태 유지·명시적 링크 복원·null 응답·중복 차단, 늦은 복원의 동의 상태 보존, 한·영 문구, 거절 시 요청 없음, 동의한 실패의 동일 payload 재시도, 고객·토큰 덮어쓰기 방지, 빈 leadId 응답, 동시 요청·확인 창 admission을 확인합니다. A3 backoff 계산·지터 범위·분류·재실행/네트워크 복구 재전송·영구오류 미재시도·동일 Idempotency-Key 유지·시도 상한, B6 코드 매핑·NSError 브리지, C3 구독 응답 파싱·에러도 확인합니다. PrivacyInfo 리소스를 파싱해 UserDefaults CA92.1만 선언하고 pasteboard 범주가 없음을 확인합니다. 실제 HTTP·구매·UIKit 화면 조작은 수행하지 않습니다.

## 결제 보고 (`reportPurchases`)

RevenueCat 등 어떤 결제 SDK로 결제했든, 결제 성공 뒤 `Codefluence.shared.reportPurchases()`를 부르면 SDK가 `Transaction.all`에서 아직 보고하지 않은 Apple 서명 거래를 읽어 `/track/purchase`로 보냅니다. 앱 시작(`configure`)과 소개 확인 직후에도 자동으로 돕니다. 소개 확인 때는 Apple 서명 `AppTransaction`을 함께 보내, 서버가 이후 거래를 `appTransactionId`로 소개에 연결합니다(iOS 16+).

- 소모성 상품은 Info.plist에 `SKIncludeConsumableInAppPurchaseHistory = YES`가 있어야 처리 완료 뒤에도 거래가 보입니다.
- 개인정보 매니페스트는 구매 내역·사용자 ID를 "사용자와 연결, 추적 아님, 개발자 광고·마케팅"으로 선언합니다. 소개 클릭과 앱 결제를 잇는 것이 Apple의 "추적"(ATT 대상)에 해당하는지는 출시 전 확인 항목입니다.
- 근거 문서: https://developer.apple.com/documentation/storekit/apptransaction/apptransactionid , https://developer.apple.com/documentation/storekit/transaction/all

## 기존 무료 사용자 귀속 옵션

첫 실행에서 토큰이 없으면 `noTokenAtLaunch` 소프트 상태로 저장하고 서버 요청 없이 일반 시작으로 처리한다
이후 랜딩 버튼으로 앱을 열어 `handle(url:)`(iOS) 또는 `handle`(Android)에 전달한 서명 형식 토큰만 다시 확인한다
이 경로에서는 클립보드와 Install Referrer를 다시 읽지 않으며 서버가 HMAC 서명·제품·만료·클릭을 검증한다
명시적 아니오는 영구 유지하고 accepted·pending·confirmedLeadId가 있으면 새 링크로 덮어쓰지 않는다
이전 SDK의 `decisionMade=true, accepted=false`는 자동 무귀속과 명시 거절을 구분할 수 없으므로 영구 유지한다

확인 요청의 `launchKind`는 기본 `first_launch`, 소프트 상태의 링크 복원은 `later`다
`later`는 클릭 캠페인과 크리에이터 그룹의 현재 발효 조건 `includeExistingUsers=true`일 때만 lead를 만든다
기본값은 false이며 미허용 응답은 `200 { "leadId": null, "reason": "existing_users_not_included" }`다
SDK는 이 응답에서 대기 큐와 해당 링크를 지우고 소프트 상태로 돌아가며 자동 재전송하지 않는다
나중에 새 링크를 열면 다시 확인할 수 있다
`autoConfirmIfAvailable`는 성공한 일반 시작으로 nil/null을 반환하며, 반환형이 문자열인 iOS 호환 `confirm`은 성공 lead가 없으므로 오류를 반환하되 영구 거절을 저장하지 않는다

기존 무료 사용자의 첫 유료 전환만 새 귀속 대상이며 기존 유료 고객은 제외한다
스토어가 검증한 최초 구매 시각이 lead 생성보다 이르면 구매 이름표·고객 ID·원 거래 참조로 대조하여 `Conversion.exclusion=existing_customer`로 남기고 보상을 만들지 않는다
갱신은 원 거래의 최초 귀속과 첫 구매의 `termsId`를 유지한다
