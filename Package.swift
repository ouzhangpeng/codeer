// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Codeer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Codeer",
            path: "Sources/Codeer",
            linkerSettings: [
                // 把 Info.plist 嵌进 binary 的 __TEXT __info_plist section，
                // 让 Bundle.main.bundleIdentifier = "com.codeer.app" 生效，
                // NSStatusItem.autosaveName 才能写进 user defaults。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
