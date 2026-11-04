import OpenClickyKit
import SwiftUI

/// The Home window: typed chat over the conversation history, background jobs, recent drawings and skills, with
/// shortcuts into Settings for memory, connected apps and services.
struct HomeView: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar()
                .frame(width: 200)
            Divider()
            Group {
                switch services.chat.section {
                case .chat: HomeChatView()
                case .agents: HomeAgentsView()
                case .drawings: HomeDrawingsView()
                case .skills: SkillsLibraryView(model: services.skills, compact: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HomeSidebar: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.rays")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("OpenClicky").font(.headline)
                    Text(talkHint).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 12)

            ForEach(HomeSection.allCases) { section in
                SidebarRow(title: section.title, symbol: section.symbol, badge: badge(section),
                           selected: services.chat.section == section) {
                    services.chat.section = section
                    if section == .drawings { services.drawings.reload() }
                    if section == .skills { services.skills.reload() }
                }
            }

            Text("SETTINGS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 4)
            ForEach([HomeServices.SettingsPage.memory, .connectedApps, .services, .voice, .talkKeys, .models]) { page in
                SidebarRow(title: page.title, symbol: page.symbol, badge: nil, selected: false) {
                    services.openSettings(page)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var talkHint: String { "\(services.talkKeys.settings.voice.phrase) to talk" }

    private func badge(_ section: HomeSection) -> String? {
        switch section {
        case .agents:
            guard let hud = services.agentHUD, !hud.feed.active.isEmpty else { return nil }
            return "\(hud.feed.active.count)"
        case .skills:
            return services.skills.activeCount > 0 ? "\(services.skills.activeCount) on" : nil
        default:
            return nil
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let badge: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                Text(title)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.18)))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agents

private struct HomeAgentsView: View {
    @Environment(HomeServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background jobs").font(.title2.weight(.semibold))
            Text("Ask OpenClicky out loud to research, write or build something and it hands the work to an agent. Jobs keep running while you work; their results come back here and in the voice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let hud = services.agentHUD {
                AgentJobsBrowserView(model: hud)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ContentUnavailableView("Agents aren't running", systemImage: "sparkles.rectangle.stack",
                                       description: Text("Pick a background agent on the Models page."))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
