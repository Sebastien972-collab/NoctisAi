import Foundation
import Testing
@testable import Noctis

struct LocalizationTests {
    @Test(arguments: ["fr", "en"])
    func includesErrorTranslations(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let key = "error.model.not_loaded"
        let value = bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable")
        #expect(value != "__missing__")
        #expect(!value.isEmpty)
        if language == "fr" {
            #expect(value == "Le modèle Noctis n'est pas encore chargé.")
        } else {
            #expect(value != key)
        }
    }

    @Test(arguments: ["fr", "en"])
    func preservesProcessExitCode(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let code: Int32 = 17
        let value = String(
            localized: "error.searxng.startup_failed",
            defaultValue: "Le processus SearXNG a échoué (code \(code)). Vérifiez le runtime et ses dépendances.",
            bundle: bundle
        )
        #expect(value.contains("17"))
        #expect(!value.contains("%d"))
    }
}
