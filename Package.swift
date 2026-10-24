// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LectureAssistant",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "LectureAssistant",
            path: "Sources/LectureAssistant",
            swiftSettings: [.unsafeFlags(["-Osize"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
