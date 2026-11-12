import XCTest
@testable import Codefluence

/// 테스트가 기대하는 빌드 종류. `swift test`(Debug 구성)는 "debug", `swift test -c release -Xswiftc -enable-testing`은
/// macOS 호스트(시뮬레이터 아님)라 "release"다. SDK가 호스트 앱과 같은 구성으로 컴파일된다는 가정을 양쪽 구성에서 확인한다.
let expectedBuild: String = {
    #if DEBUG
    return "debug"
    #else
    return "release"
    #endif
}()

final class BuildKindTests: XCTestCase {
    func testBuildFollowsTheCompilationConfiguration() {
        XCTAssertEqual(Codefluence.build, expectedBuild)
        XCTAssertTrue(["debug", "release"].contains(Codefluence.build), "서버 계약은 두 값만 받는다")
    }
}
