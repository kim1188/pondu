// swift-tools-version: 5.9
import Foundation
import PackageDescription

// 흐름 F 소유. 계약 5절의 타깃을 모두 선언한다.
//
// 기능 타깃(FeatureSession, FeatureRecord, FeatureTogether, FeatureToday)의 폴더는 각 흐름(G, H, I)이 만든다.
// 흐름별 브랜치에서는 다른 흐름의 폴더가 없어 패키지가 깨지므로, 폴더가 있는 타깃만 선언한다.
// 네 흐름이 모두 병합된 뒤에는 아래 목록이 전부 선언된 것과 같다. 병합 순서는 ios/README.md 참고.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

func directoryExists(_ relativePath: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: packageDirectory + "/" + relativePath, isDirectory: &isDirectory) && isDirectory.boolValue
}

/// 기능 타깃 이름과 테스트 폴더 이름.
let featureTargets = ["FeatureAuth", "FeatureSession", "FeatureRecord", "FeatureTogether", "FeatureToday"]

var products: [Product] = [.library(name: "PonduCore", targets: ["PonduCore"])]
var targets: [Target] = [
    .target(
        name: "PonduCore",
        dependencies: [.product(name: "Supabase", package: "supabase-swift")]
    ),
    .testTarget(name: "PonduCoreTests", dependencies: ["PonduCore"]),
]

for feature in featureTargets where directoryExists("Sources/\(feature)") {
    products.append(.library(name: feature, targets: [feature]))
    targets.append(.target(name: feature, dependencies: ["PonduCore"]))
    if directoryExists("Tests/\(feature)Tests") {
        targets.append(.testTarget(name: "\(feature)Tests", dependencies: [.target(name: feature), "PonduCore"]))
    }
}

let package = Package(
    name: "PonduKit",
    platforms: [.iOS(.v17)],
    products: products,
    dependencies: [
        // 외부 의존성은 이것 하나뿐(계약 5절). 2.x 최신 안정판이 Swift 6.1 도구(Xcode 26)를 요구한다.
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
    ],
    targets: targets
)
