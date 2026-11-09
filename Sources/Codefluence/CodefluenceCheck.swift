import Foundation

/// 한 가지 설치 점검 결과. `Codefluence.validate`가 돌려줍니다.
public struct CodefluenceCheck: Equatable {
    public let name: String
    public let passed: Bool
    /// 통과하면 확인한 내용, 실패하면 무엇을 고쳐야 하는지.
    public let hint: String
    public init(name: String, passed: Bool, hint: String) { self.name = name; self.passed = passed; self.hint = hint }
}
