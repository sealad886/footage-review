// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FootageReview",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "FootageReview", targets: ["FootageReview"])],
    targets: [
        .executableTarget(name: "FootageReview"),
        .testTarget(name: "FootageReviewTests", dependencies: ["FootageReview"])
    ]
)
