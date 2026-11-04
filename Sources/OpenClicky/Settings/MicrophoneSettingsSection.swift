import OpenClickyKit
import SwiftUI

/// Settings → Voice: the microphone to listen with (picking one drops a failover pin to the built-in mic), what happens
/// when the Mac is muted, echo cancellation for always-on on speakers, and quiet times (docs/audio-robustness.md).
struct MicrophoneSettingsSections: View {
    @Environment(AppModel.self) private var model
    @ViewState private var inputs: [AudioDeviceInfo] = []
    @ViewState private var verdict: String = ""
    @ViewState private var quietStatus: String = ""
    /// The failover to the built-in mic, if capture is pinned there (read on appear and after a choice).
    @ViewState private var failover: Failover? = nil

    struct Failover: Equatable {
        var from: String?
        var to: String
    }

    var body: some View {
        if let loop = model.voiceLoop {
            Section {
                Picker("Listen with", selection: Binding(get: { loop.settings.microphoneUID ?? "" }, set: { uid in
                    loop.chooseMicrophone(uid.isEmpty ? nil : uid)
                    refresh()
                })) {
                    Text("System default" + (inputs.first(where: \.isDefaultInput).map { " (\($0.name))" } ?? "")).tag("")
                    ForEach(inputs) { device in
                        Text("\(device.name) · \(device.transport.description)").tag(device.uid)
                    }
                    if let chosen = loop.settings.microphoneUID, !inputs.contains(where: { $0.uid == chosen }) {
                        Text("Not connected").tag(chosen)
                    }
                }
                if let failover {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(failover.from ?? "Your microphone") stopped sending audio, so OpenClicky is listening with \(failover.to). Pick a microphone above, or try it again.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Try \(failover.from ?? "it") again") {
                            loop.chooseMicrophone(loop.settings.microphoneUID)
                            refresh()
                        }
                    }
                }
                Toggle("When the Mac is muted, answer on screen and offer to unmute", isOn: binding(loop, \.handlesMutedOutput))
            } header: {
                Text("Microphone")
            } footer: {
                Text("If the microphone stops sending audio, OpenClicky reconnects it, then switches to the Mac's own microphone and tells you. A muted Mac gets the answer as captions, copied to the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Echo cancellation", selection: Binding(get: { loop.settings.echoCancellation }, set: { mode in
                    var settings = loop.settings
                    settings.echoCancellation = mode
                    loop.update(settings)
                })) {
                    Text("Automatic").tag(EchoCancellationMode.automatic)
                    Text("Off (headphones only)").tag(EchoCancellationMode.off)
                }
                .pickerStyle(.segmented)
                LabeledContent("These devices", value: verdict)
                Button("Test echo cancellation again") {
                    loop.audio.router.forgetVerdict(inputUID: loop.settings.microphoneUID)
                    refresh()
                }
                .buttonStyle(.link)
            } header: {
                Text("Always-on voice on speakers")
            } footer: {
                Text("With echo cancellation the microphone doesn't hear OpenClicky's own voice, so always-on works without headphones. It's tested once for each microphone and speaker pair; where it doesn't work, always-on asks for headphones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Hold job reports and reminders during calls and Focus", isOn: binding(loop, \.holdsDuringQuiet))
                LabeledContent("Now", value: quietStatus)
            } header: {
                Text("Quiet times")
            } footer: {
                Text("While you're on a call, another app is recording, or a Focus is on, OpenClicky doesn't speak up on its own: finished jobs, routine runs, meeting countdowns and setup reminders wait until it's over. Anything you ask still gets an answer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        inputs = AudioDevices.inputs()
        guard let loop = model.voiceLoop else { return }
        failover = loop.audio.failover.map { Failover(from: $0.from, to: $0.to) }
        let topology = AudioTopology.current(inputUID: loop.settings.microphoneUID)
        switch loop.audio.router.verdicts.verdict(for: topology) {
        case .promoted?: verdict = "works here"
        case .zombie(let reason, _)?: verdict = "doesn't work here (\(reason))"
        case nil: verdict = "not tested yet"
        }
        loop.audio.quiet.refresh()
        let quiet = loop.audio.quiet
        quietStatus = quiet.context.isQuiet ? quiet.context.summary.prefix(1).uppercased() + quiet.context.summary.dropFirst()
            + (quiet.gate.heldSummary.map { " · " + $0 } ?? "") : "Not quiet"
    }

    private func binding(_ loop: VoiceLoopController, _ key: WritableKeyPath<VoiceLoopSettings, Bool>) -> Binding<Bool> {
        Binding(get: { loop.settings[keyPath: key] }, set: { value in
            var settings = loop.settings
            settings[keyPath: key] = value
            loop.update(settings)
        })
    }
}
