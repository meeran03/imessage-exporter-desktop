// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageArchive",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MessageArchive", targets: ["MessageArchive"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "BodyDecoder", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "ArchiveCore", dependencies: ["CSQLite", "BodyDecoder"]),
        .executableTarget(name: "MessageArchive", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"])
    ],
    swiftLanguageModes: [.v5]
)
