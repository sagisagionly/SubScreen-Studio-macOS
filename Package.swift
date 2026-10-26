// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SubScreenStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SubScreenStudio", targets: ["SubScreenStudio"])
    ],
    targets: [
        .executableTarget(
            name: "SubScreenStudio",
            path: "Sources/SubScreenStudio",
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("EventKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit")
            ]
        )
    ]
)
