// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasteWhat",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PasteWhat", targets: ["PasteWhat"])],
    targets: [
        .executableTarget(
            name: "PasteWhat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
