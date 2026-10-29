import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var keyDraft = ""
    @State private var keyStatus: KeyStatus = .idle

    private let network = RailNetwork.shared

    enum KeyStatus: Equatable {
        case idle, checking, valid, invalid(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                stationsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        settings.setAPIKey(keyDraft)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { keyDraft = settings.apiKey }
        .onDisappear { settings.setAPIKey(keyDraft) }
    }

    // MARK: Sections

    private var apiKeySection: some View {
        Section {
            TextField("Paste your key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit { Task { await checkKey() } }

            Button {
                Task { await checkKey() }
            } label: {
                HStack {
                    Text("Save & test key")
                    Spacer()
                    keyStatusView
                }
            }
            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || keyStatus == .checking)

            Link(destination: MetrolinxClient.registrationURL) {
                Label("Request a free key from Metrolinx", systemImage: "arrow.up.right.square")
            }
        } header: {
            Text("Metrolinx API key")
        } footer: {
            Text("Live departures come straight from Metrolinx Open Data. Approval is manual and can take a few business days. The key is stored in your iCloud Keychain and only ever sent to api.openmetrolinx.com.")
        }
    }

    @ViewBuilder
    private var keyStatusView: some View {
        switch keyStatus {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
        case .valid:
            Label("Works", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var stationsSection: some View {
        Section {
            NavigationLink {
                StationPicker(title: "Home station", selection: settings.homeCode) { settings.setHome($0) }
            } label: {
                LabeledContent {
                    Text(name(for: settings.homeCode))
                } label: {
                    Label("Home", systemImage: "house.fill")
                }
            }
            NavigationLink {
                StationPicker(title: "Work station", selection: settings.workCode) { settings.setWork($0) }
            } label: {
                LabeledContent {
                    Text(name(for: settings.workCode))
                } label: {
                    Label("Work", systemImage: "briefcase.fill")
                }
            }
        } header: {
            Text("Your stations")
        } footer: {
            Text("When you open the app it shows the board for the station you're at, or whichever of these is closer to you. Synced with iCloud.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Network data", value: network.feedVersion.isEmpty ? "Bundled" : String(network.feedVersion.prefix(8)))
            LabeledContent("Stations", value: "\(network.stations.count)")
        } header: {
            Text("About")
        } footer: {
            Text("Contains information licensed under the Open Government Licence – Ontario (Metrolinx). Not affiliated with or endorsed by Metrolinx or GO Transit. Free, open source, no ads, no tracking.")
        }
    }

    // MARK: Helpers

    private func name(for code: String?) -> String {
        guard let code else { return "Not set" }
        return network.station(code)?.name ?? code
    }

    private func checkKey() async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyStatus = .checking
        do {
            let _: NextServiceResponse = try await MetrolinxClient(apiKey: key).fetch("/Stop/NextService/UN")
            settings.setAPIKey(key)
            keyStatus = .valid
        } catch MetrolinxError.badKey {
            keyStatus = .invalid("Rejected")
        } catch {
            keyStatus = .invalid("Couldn't check")
        }
    }
}

struct StationPicker: View {
    let title: String
    let selection: String?
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let network = RailNetwork.shared

    private var filtered: [Station] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return network.stations }
        return network.stations.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if selection != nil, query.isEmpty {
                Button(role: .destructive) {
                    onPick(nil)
                    dismiss()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
            ForEach(filtered) { station in
                Button {
                    onPick(station.code)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(station.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach(station.lineCodes, id: \.self) { LineBadge(code: $0) }
                        }
                        if station.code == selection {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station")
    }
}
