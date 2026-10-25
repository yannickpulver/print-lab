import Foundation
import ProjectDescription

/// The repo-root `VERSION` file is the single source of truth: CI reads it for the tag and the cask.
let appVersion: String = {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("VERSION")
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.isEmpty ? "dev" : version
}()

let project = Project(
    name: "PrintLab",
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
        // CI passes `CURRENT_PROJECT_VERSION=<run number>`.
        "CURRENT_PROJECT_VERSION": "1",
    ]),
    targets: [
        .target(
            name: "PrintLab",
            destinations: .macOS,
            product: .app,
            bundleId: "com.yannickpulver.PrintLab",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Print Lab",
                "CFBundleShortVersionString": .string(appVersion),
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSApplicationCategoryType": "public.app-category.photography",
                // Status from the printer's own web page (plain HTTP on the local network).
                "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "com.yannickpulver.PrintLab",
                        "CFBundleURLSchemes": ["printlab"],
                    ],
                ],
                "CFBundleDocumentTypes": [
                    [
                        "CFBundleTypeName": "Image",
                        "CFBundleTypeRole": "Viewer",
                        "LSHandlerRank": "Alternate",
                        "LSItemContentTypes": ["public.image"],
                    ],
                ],
            ]),
            sources: ["App/Sources/**"],
            resources: ["App/Resources/**"]
        ),
        .target(
            name: "PrintLabTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.yannickpulver.PrintLabTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["App/Tests/**"],
            dependencies: [.target(name: "PrintLab")]
        ),
    ]
)
