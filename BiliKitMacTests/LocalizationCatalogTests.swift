import Foundation
import Testing

struct LocalizationCatalogTests {
    private let supportedLanguages = ["zh-Hans", "zh-Hant", "ja", "en"]

    @Test
    func builtAppContainsFourLocalizedResourceSets() throws {
        let appBundle = Bundle.main
        #expect(appBundle.bundleIdentifier == "com.shiinayane.BiliKit")
        try expectFourLocalizations(in: appBundle, label: "BiliKit.app")

        let featureBundleNames = [
            "BiliKitCore_BiliAuthFeature",
            "BiliKitCore_BiliBrowseFeature",
            "BiliKitCore_BiliLibraryFeature"
        ]
        for name in featureBundleNames {
            let url = try #require(
                appBundle.resourceURL?.appending(path: "\(name).bundle")
            )
            let bundle = try #require(Bundle(url: url), "Missing \(name).bundle")
            try expectFourLocalizations(in: bundle, label: name)
        }
    }

    private func expectFourLocalizations(
        in bundle: Bundle,
        label: String
    ) throws {
        #expect(
            Set(bundle.localizations) == Set(supportedLanguages),
            "\(label) must contain exactly four localizations"
        )
        #expect(bundle.developmentLocalization == "zh-Hans")
        for language in supportedLanguages {
            let resource = bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: language
            )
            #expect(resource != nil, "\(label) is missing \(language).lproj/Localizable.strings")
        }
    }
}
