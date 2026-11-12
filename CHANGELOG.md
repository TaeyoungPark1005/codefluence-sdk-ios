# 변경 기록

## 0.2.2

- **미전송 구매 영속 큐.** 구매 보고를 기기에 저장하고 서버가 2xx로 받을 때까지 다시 보냅니다(네트워크 오류·5xx·429·409 `credential_missing`은 재시도, 401·403은 하루 간격으로 보존, 그 밖의 4xx는 제거). 위치는 백업 제외한 `Application Support/Codefluence/purchase-queue.json`, 상한 100건·90일, 거래 ID로 중복 방지. 소개로 온 설치만 저장합니다.
- **결제 직후 거래를 직접 넘기는 호출.** `purchaseCompleted(jws:)`, `purchaseCompleted(transaction:)`(StoreKit 2 `VerificationResult<Transaction>`), `purchaseCompleted(storeTransaction:)`(RevenueCat `StoreTransaction`). 다른 결제 SDK(RevenueCat 등)를 쓰는 앱은 결제 완료 콜백에서 이 호출을 써야 iOS 15~17의 소모성 결제가 빠지지 않습니다. 인자 없는 `purchaseCompleted()`는 그대로이며 같은 큐를 씁니다.
- **`appTransaction` 필드.** 구매 보고 본문에 Apple 서명 AppTransaction JWS를 선택 필드로 싣습니다(확인 때 lead에 묶이지 못한 AppTransaction 재전송). 모르는 필드를 무시하는 서버에는 영향이 없습니다.
- `build` 필드, 서버 플래그 꺼짐 시 동작 등 0.2.1의 규칙은 그대로입니다.

예제는 README 「미전송 구매 큐 (0.2.2)」.
