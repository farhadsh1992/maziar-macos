// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Maziar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Maziar",
            path: "Sources/Maziar",
            resources: [
                .copy("Resources/Templates"),
                .copy("Resources/Logo.png"),
                .copy("Resources/CVAutoFillLogo.png")
            ]
        )
    ]
)
