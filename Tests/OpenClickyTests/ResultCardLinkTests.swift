import Foundation
import SwiftUI
import Testing
import OpenClickyKit
@testable import OpenClicky

// Links in a result card go through the action the app gives the panel (the URL router), not LaunchServices.
@Suite @MainActor struct ResultCardLinkTests {
    @Test func theResultCardPanelHostsTheRouterLinkAction() throws {
        let panel = AgentResultCardPanel()
        var opened: [URL] = []
        panel.openURL = OpenURLAction { url in opened.append(url); return .handled }
        panel.preparedPanel()
        let host = try #require(panel.hostingView, "the card panel hosts AgentResultCardHost")
        host.rootView.openURL(URL(string: "openclicky:job/pricing-articles-3f2a91c0de")!)
        host.rootView.openURL(URL(string: "openclicky://settings/usage")!)
        #expect(opened.map(\.absoluteString) == ["openclicky:job/pricing-articles-3f2a91c0de", "openclicky://settings/usage"])
        panel.hide()
    }

    @Test func everyHomeSettingsPageHasALinkPageAndBack() {
        for page in HomeServices.SettingsPage.allCases {
            let id = SettingsPageID(rawValue: page.rawValue)
            #expect(id != nil, "Settings page \(page.rawValue) has no openclicky://settings link")
            #expect(id.flatMap { OpenClickyURLRouter.parse("openclicky://settings/\($0.rawValue)").route } == .settings(id))
        }
        for id in SettingsPageID.allCases {
            #expect(HomeServices.SettingsPage(id) != nil, "link page \(id.rawValue) has no Settings page")
        }
    }
}
