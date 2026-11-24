// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Maziar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Maziar",
            path: "Sources/Maziar",
            // Notes for Claude Code about the Library section, not part of the app.
            exclude: ["Library/CLAUDE.md", "Library/code.md"],
            resources: [
                .copy("Resources/Templates"),
                .copy("Resources/Logo.png"),
                .copy("Resources/CVAutoFillLogo.png")
            ]
        ),
        .executableTarget(name: "NumenorAI", path: "Numenor/scripts/native-ai"),
        // Spelling/grammar helper for the embedded OpenPrism editor (see Sources/MaziarSpell/main.swift).
        .executableTarget(
            name: "MaziarSpell",
            path: "Sources/MaziarSpell"
        )
    ]
)
