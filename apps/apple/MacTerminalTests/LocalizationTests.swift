import Foundation
import XCTest

@MainActor final class LocalizationTests: XCTestCase {
    func testAppShipsBothLanguagesAndEnglishFallback() throws {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertTrue(Bundle.main.localizations.contains("en"))
        XCTAssertTrue(Bundle.main.localizations.contains("zh-Hans"))
        for (language, title, done) in [("en", "Terminal Display", "Done"),
                                      ("zh-Hans", "终端显示", "完成")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Terminal Display", value: nil, table: nil), title)
            XCTAssertEqual(bundle.localizedString(forKey: "Done", value: nil, table: nil), done)
            let format = bundle.localizedString(forKey: "Font preview, %lld pt", value: nil, table: nil)
            let preview = String(format: format, Int64(24))
            XCTAssertEqual(preview, language == "en" ? "Font preview, 24 pt" : "字号预览，24 磅")
            let privacy = bundle.localizedString(forKey: "NSLocalNetworkUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertEqual(privacy, language == "en" ? "Connect to Witerm servers on your local network." : "连接同一网络中的 Witerm 服务器。")
            let camera = bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertEqual(camera, language == "en" ? "Scan a pairing invitation from your Mac." : "扫描 Mac 上的配对邀请。")
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                     forPreferences: ["en-GB"]).first, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                     forPreferences: ["zh-Hans-SG"]).first, "zh-Hans")
        XCTAssertEqual(Bundle.preferredLocalizations(from: Bundle.main.localizations,
                                                     forPreferences: ["fr-FR", "en"]).first, "en")
    }
}
