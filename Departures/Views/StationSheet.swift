import SwiftUI

/// Bottom sheet for one station: its name and lines, the board below. Tapping a
/// train opens its stop list in another sheet.
struct StationSheet: View {
    let station: Station

    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var model = BoardModel()
    @State private var selectedTrip: TripSelection?
    /// Bumped when the app comes back to the foreground, restarting the refresh loop
    /// so the board updates right away instead of waiting out the interval.
    @State private var wake = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BoardView(
                        rows: model.snapshot?.rows ?? [],
                        station: station,
                        now: context.date,
                        message: boardMessage,
                        isLoading: model.snapshot == nil && model.errorMessage == nil,
                        isScheduled: model.snapshot?.source == .schedule
                    ) { row in
                        selectedTrip = TripSelection(row: row, station: station)
                    }
                }
                statusLine
                alerts
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // No pull-to-refresh: pulling down closes the sheet. The board keeps
        // itself current instead.
        // Paused while a trip sheet covers this board; resumes (and refreshes) when it closes.
        .task(id: "\(station.code)#\(wake)#\(selectedTrip == nil)") {
            guard selectedTrip == nil else { return }
            await model.run(station: station)
        }
        .sheet(item: $selectedTrip) { trip in
            TripSheet(selection: trip)
                .environment(settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { wake += 1 }
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

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Close")
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if snapshot.source == .schedule {
                    Image(systemName: "calendar")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Scheduled times, not live: no delays or platforms")
                        if let note = snapshot.note {
                            Text(note)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if model.errorMessage != nil {
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
