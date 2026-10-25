import ProjectDescription

let project = Project(
    name: "CanonPrintLab",
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "MACOSX_DEPLOYMENT_TARGET": "26.0",
    ]),
    targets: [
        .target(
            name: "CanonPrintLab",
            destinations: .macOS,
            product: .app,
            bundleId: "com.yannickpulver.CanonPrintLab",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Canon Print Lab",
                "LSApplicationCategoryType": "public.app-category.photography",
                // Status from the printer's own web page (plain HTTP on the local network).
                "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "com.yannickpulver.CanonPrintLab",
                        "CFBundleURLSchemes": ["canonprintlab"],
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
            name: "CanonPrintLabTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.yannickpulver.CanonPrintLabTests",
            deploymentTargets: .macOS("26.0"),
            sources: ["App/Tests/**"],
            dependencies: [.target(name: "CanonPrintLab")]
        ),
    ]
)
