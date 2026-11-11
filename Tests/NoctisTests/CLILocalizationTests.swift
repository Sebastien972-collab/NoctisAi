// Created by Sébastien DAGUIN

import Foundation
import Testing
@testable import NoctisCLI

// Resolve the CLI resource bundle in a file that imports only this target.
func localizedCLI(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

struct CLILocalizationTests {
    @Test(arguments: ["fr", "en"])
    func includesGlobalCLITranslations(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in ["console.cli.usage", "console.cli.interactive_help", "Latest stable version:",
                    "An update is available.", "Unsafe installation path.",
                    "console.permissions.summary", "console.workspace.confirm",
                    "console.workspace.explicit_flag", "console.history.cleared", "console.status.cancelled"] {
            #expect(bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable") != "__missing__")
        }
    }

    @Test(arguments: ["fr", "en"])
    func includesLocalizedResources(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let key = "console.hint.exit"
        let value = bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable")
        #expect(value != "__missing__")
        #expect(value.contains("exit"))
    }
}

func localizedCLIError(_ description: String) -> String {
    String(localized: "console.error.details", defaultValue: "Erreur : \(description)", bundle: .module)
}
