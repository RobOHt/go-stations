import SwiftUI

/// Bottom sheet for one station: name and home/work toggles on glass, the board below.
struct StationSheet: View {
    let station: Station
    let onClose: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var model = BoardModel()
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if settings.hasAPIKey {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        BoardView(
                            rows: model.snapshot?.rows ?? [],
                            station: station,
                            now: context.date,
                            message: boardMessage,
                            isLoading: model.snapshot == nil && model.errorMessage == nil
                        )
                    }
                    statusLine
                    alerts
                } else {
                    MissingKeyCard { showSettings = true }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await model.refresh(station: station, apiKey: settings.apiKey)
        }
        .task(id: "\(station.code)|\(settings.apiKey)") {
            await model.run(station: station, apiKey: settings.apiKey)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var boardMessage: String? {
        if let error = model.errorMessage, model.snapshot == nil { return error }
        if model.snapshot == nil { return "Loading | Chargement" }
        return nil
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(station.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    ForEach(station.lineCodes, id: \.self) { code in
                        LineBadge(code: code)
                    }
                    if let role = roleLabel {
                        Text(role)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }
            }

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        settings.setHome(settings.homeCode == station.code ? nil : station.code)
                    } label: {
                        Image(systemName: settings.homeCode == station.code ? "house.fill" : "house")
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel(settings.homeCode == station.code ? "Remove as home station" : "Set as home station")

                    Button {
                        settings.setWork(settings.workCode == station.code ? nil : station.code)
                    } label: {
                        Image(systemName: settings.workCode == station.code ? "briefcase.fill" : "briefcase")
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel(settings.workCode == station.code ? "Remove as work station" : "Set as work station")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 22, height: 22)
                    }
                    .accessibilityLabel("Close")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
        }
    }

    private var roleLabel: String? {
        switch (settings.homeCode == station.code, settings.workCode == station.code) {
        case (true, true): return "Home · Work"
        case (true, false): return "Home"
        case (false, true): return "Work"
        default: return nil
        }
    }

    // MARK: Below the board

    @ViewBuilder
    private var statusLine: some View {
        if let snapshot = model.snapshot {
            HStack(spacing: 6) {
                if model.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Couldn't refresh · showing \(TorontoTime.hourMinute(snapshot.fetchedAt))")
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Live · updated \(TorontoTime.clock(snapshot.fetchedAt))")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var alerts: some View {
        if let alerts = model.snapshot?.alerts, !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(alerts) { alert in
                    AlertCard(alert: alert)
                }
            }
        }
    }
}

private struct AlertCard: View {
    let alert: StationAlert
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.subjectEnglish)
                            .font(.subheadline.weight(.semibold))
                        if !alert.subjectFrench.isEmpty {
                            Text(alert.subjectFrench)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if !alert.body.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                if expanded, !alert.body.isEmpty {
                    Text(alert.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct MissingKeyCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add your Metrolinx API key", systemImage: "key.fill")
                .font(.headline)
            Text("GO Stations reads live data straight from Metrolinx's free Open Data API. Paste your key once and it syncs to your other devices through iCloud Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Settings", action: action)
                    .buttonStyle(.glassProminent)
                Link("Get a free key", destination: MetrolinxClient.registrationURL)
                    .buttonStyle(.glass)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
