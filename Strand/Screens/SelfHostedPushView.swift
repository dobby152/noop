import SwiftUI
import StrandDesign
import WhoopPush

/// Self-hosted push (Experimental, off by default). One-way export of selected rows to an HTTPS endpoint
/// the user owns (docs/PUSH_PROTOCOL.md v1). NOOP never reads anything back from the receiver.
struct SelfHostedPushView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var push = SelfHostedPush.shared

    @State private var enabled = SelfHostedPushSettings.enabled
    @State private var endpoint = SelfHostedPushSettings.endpoint
    @State private var wifiOnly = SelfHostedPushSettings.wifiOnly
    @State private var tokenInput = ""
    @State private var hasToken = PushTokenStore.hasToken
    @State private var testing = false
    @State private var testStatus: SelfHostedPush.Status?

    private var endpointValid: Bool { (try? EndpointPolicy.validate(endpoint)) != nil }
    private var canEnable: Bool { endpointValid && hasToken }

    var body: some View {
        ScreenScaffold(
            title: "Odesílání na vlastní server",
            subtitle: "Experimentální. Posílá data z pásku jedním směrem na server, který vlastníš. Dokud to nezapneš, je vypnuto."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                destinationCard
                controlCard
            }
        }
    }

    // MARK: - Cards

    private var destinationCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cíl")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)

                TextField("https://tvuj-server.example/push", text: Binding(
                    get: { endpoint },
                    set: { endpoint = $0; SelfHostedPushSettings.endpoint = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif

                if !endpoint.isEmpty && !endpointValid {
                    Text("Použij adresu https://. Obyčejné http:// se přijímá jen pro soukromou IP adresu ve tvé vlastní síti.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SecureField(hasToken ? "Token je uložený. Zadáním nového ho nahradíš" : "Token (Bearer)", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                HStack(spacing: 10) {
                    NoopButton("Uložit token", systemImage: "key.fill", kind: .secondary) { saveToken() }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasToken {
                        NoopButton("Smazat token", systemImage: "trash", kind: .tertiary) { removeToken() }
                    }
                }

                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jen Wi-Fi")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text("Nepoužije mobilní data ani hotspot.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Toggle("Jen Wi-Fi", isOn: Binding(
                        get: { wifiOnly },
                        set: { wifiOnly = $0; SelfHostedPushSettings.wifiOnly = $0 }
                    ))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                }
            }
        }
    }

    private var controlCard: some View {
        StrandCard(padding: 20, tint: enabled ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Odesílat data")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text(canEnable
                             ? "Spustí se po synchronizaci pásku a při otevření NOOPu. Synchronizaci pásku nikdy nezdržuje."
                             : "Nejdřív zadej platnou adresu a token.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Odesílat data", isOn: Binding(
                        get: { enabled },
                        set: { setEnabled($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .disabled(!canEnable && !enabled)
                }

                HStack(spacing: 10) {
                    NoopButton(testing ? "Testuji…" : "Otestovat spojení", systemImage: "network", kind: .secondary) { runTest() }
                        .disabled(!canEnable || testing)
                    NoopButton("Odeslat teď", systemImage: "arrow.up.circle", kind: .secondary) { model.triggerSelfHostedPush() }
                        .disabled(!enabled)
                }

                Text(statusLine)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Test jen ověří, že server odpovídá. Nečte žádná zdravotní data ani žádná neposílá.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func setEnabled(_ on: Bool) {
        enabled = on
        SelfHostedPushSettings.enabled = on
        if on { model.triggerSelfHostedPush() }
    }

    private func saveToken() {
        if PushTokenStore.save(tokenInput) { tokenInput = "" }
        hasToken = PushTokenStore.hasToken
    }

    private func removeToken() {
        PushTokenStore.clear()
        hasToken = false
        setEnabled(false)
    }

    private func runTest() {
        testing = true
        testStatus = nil
        Task {
            let result = await push.testConnection()
            testStatus = result
            testing = false
        }
    }

    private var statusLine: String {
        let shown = testStatus ?? push.status
        switch shown {
        case .idle: return "Zatím neproběhlo."
        case .running: return "Odesílám…"
        case let .succeeded(date): return "Naposledy úspěšně: \(date.formatted(date: .abbreviated, time: .shortened))"
        case let .failed(code): return "Selhalo (\(code)). Při dočasné příčině se to zkusí samo znovu."
        }
    }
}
