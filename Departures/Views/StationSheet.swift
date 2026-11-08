import SwiftUI
import UIKit

/// Bottom sheet for one station: name, lines and home/work toggles on glass, the
/// board below. Tapping a train opens its stop list in another sheet.
struct StationSheet: View {
    let station: Station

    @Environment(AppSettings.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var model = BoardModel()
    @State private var selectedTrip: TripSelection?
    /// Trains that already left, when asked for (nil while hidden).
    @State private var earlierRows: [BoardRow]?
    /// On your home or work board: every train, not just the ones toward the other.
    @State private var showsAllDirections = false
    /// Timetable trains after the live ones, so the board always shows a few trains
    /// (your way, when it's filtered), however far ahead the next ones are.
    @State private var laterRows: [BoardRow] = []
    /// What the home or work button is about to do, asked first. Worked out when the
    /// button is tapped, so the words don't change while the dialog closes.
    @State private var roleDialog = RoleDialog()
    @State private var showsHomeDialog = false
    @State private var showsWorkDialog = false
    /// Bumped when the app comes back to the foreground, restarting the refresh loop
    /// so the board updates right away instead of waiting out the interval.
    @State private var wake = 0
    #if DEBUG
    @State private var debugScroll = ScrollPosition(edge: .top)
    #endif

    var body: some View {
        // On your home board only the trains toward work, on your work board only the
        // ones toward home, unless you ask for them all.
        let commute = self.commute
        let filter = showsAllDirections ? nil : commute?.direction
        let allRows = model.snapshot?.rows ?? []
        let live = filter.map { allRows.filter($0.includes) } ?? allRows
        // Never an empty board: when the live trains run out (a quiet evening, a
        // weekend), the timetable's next ones follow, tomorrow's or Monday's if need be.
        let liveTrips = Set(allRows.map(\.tripNumber))
        let later = model.snapshot == nil ? [] : (filter.map { laterRows.filter($0.includes) } ?? laterRows)
            .filter { !liveTrips.contains($0.tripNumber) }
        let added = Array(later.prefix(max(0, Self.minimumRows - live.count)))
        let rows = live + added
        let earlier = earlierRows.map { list in filter.map { list.filter($0.includes) } ?? list }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BoardView(
                        rows: rows,
                        station: station,
                        now: context.date,
                        message: boardMessage ?? (rows.isEmpty && !allRows.isEmpty
                            ? commute.map { $0.toward == .work ? "No trains toward work | Aucun train vers le travail"
                                                               : "No trains toward home | Aucun train vers la maison" }
                            : nil),
                        isLoading: model.snapshot == nil && model.errorMessage == nil,
                        isScheduled: model.snapshot?.source == .schedule,
                        onSelectRow: { row in
                            selectedTrip = TripSelection(row: row, station: station, fromBoard: true)
                        },
                        earlierRows: earlier,
                        onToggleEarlier: { toggleEarlier() },
                        timetableRowIDs: Set(added.map(\.id)),
                        direction: commute.map { commute in
                            BoardDirection(toward: commute.toward, showsAll: showsAllDirections) {
                                withAnimation(.snappy) { showsAllDirections.toggle() }
                            }
                        }
                    )
                }
                statusLine(addsTimetable: !added.isEmpty)
                alerts
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 32)
        }
        #if DEBUG
        .scrollPosition($debugScroll)
        #endif
        .scrollIndicators(.hidden)
        // The name, lines and buttons stay pinned in a bar over the board.
        .pinnedHeader { header }
        .environment(\.glassBackdrop, .sheet)
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
        // Another station in the same sheet starts out filtered again.
        .onChange(of: station.code) { _, _ in
            showsAllDirections = false
            laterRows = []
        }
        // The timetable's trains after the live ones, worked out again when those move on.
        .task(id: laterKey) {
            guard let snapshot = model.snapshot else { return }
            let after = max(snapshot.rows.map(\.scheduled).max() ?? .distantPast, Date())
            laterRows = await BoardService.shared.laterRows(
                for: station, after: after, limit: Self.minimumRows,
                toward: showsAllDirections ? nil : commute?.direction)
        }
        #if DEBUG
        // Screenshots: `-showAllDirections YES` opens home and work boards unfiltered.
        .onAppear { if UserDefaults.standard.bool(forKey: "showAllDirections") { showsAllDirections = true } }
        #endif
        // Trains that just left move into the earlier list while it's open.
        .onChange(of: model.snapshot?.fetchedAt) { _, _ in
            guard earlierRows != nil else { return }
            Task { await loadEarlier() }
        }
        #if DEBUG
        // Screenshot scenes: tap home or work once the sheet is up.
        .task {
            if DebugScene.current == .stationEarlier {
                try? await Task.sleep(for: .seconds(2))
                toggleEarlier()
                return
            }
            guard let scene = DebugScene.current, scene == .homeDialog || scene == .workDialog else { return }
            try? await Task.sleep(for: .seconds(2))
            let role: Role = scene == .homeDialog ? .home : .work
            roleDialog = dialog(for: role)
            if role == .home { showsHomeDialog = true } else { showsWorkDialog = true }
        }
        #endif
        #if DEBUG
        // Screenshot scene: open the first train once the board has loaded.
        .onChange(of: model.snapshot?.rows.first?.id) { _, _ in
            if DebugScene.current == .stationScrolled, model.snapshot != nil {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation { debugScroll.scrollTo(y: 320) }
                }
            }
            guard DebugScene.current == .trip, selectedTrip == nil,
                  let row = model.snapshot?.rows.first else { return }
            selectedTrip = TripSelection(row: row, station: station, fromBoard: true)
        }
        #endif
    }

    private func toggleEarlier() {
        if earlierRows != nil {
            withAnimation(.snappy) { earlierRows = nil }
        } else {
            Task { await loadEarlier() }
        }
    }

    private func loadEarlier() async {
        let rows = await BoardService.shared.earlierRows(for: station)
        withAnimation(.snappy) { earlierRows = rows }
    }

    private var boardMessage: String? {
        if let error = model.errorMessage, model.snapshot == nil { return error }
        if model.snapshot == nil { return "Loading | Chargement" }
        return nil
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if settings.homeCode == nil && settings.workCode == nil {
                // Nobody's set up yet: what the two buttons are for.
                Text("Tap \(Image(systemName: "house")) or \(Image(systemName: "briefcase")) to make this your home or work station.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(station.name)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // Wraps onto a second line when there are many lines (Union has seven).
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(station.lineCodes, id: \.self) { code in
                        LineBadge(code: code)
                    }
                    if let role = roleLabel {
                        Text(role)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(roleColor)
                            .fixedSize()
                            .padding(.leading, 4)
                    }
                }
            }
            .padding(.top, PinnedHeaderMetrics.textTop)

            Spacer(minLength: 8)

            // Home and work share one glass, the close button has its own.
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    GlassButtonGroup(axis: .horizontal) {
                        // Each asks first, in an action sheet that comes out of the button
                        // (the HIG's pattern for confirming something you just chose).
                        Button {
                            roleDialog = dialog(for: .home)
                            showsHomeDialog = true
                        } label: {
                            GlassIcon(systemName: isHome ? "house.fill" : "house",
                                      fill: isHome ? RoleColor.home : nil)
                        }
                        .accessibilityLabel(isHome ? "Remove as home station" : "Set as home station")
                        .accessibilityAddTraits(isHome ? .isSelected : [])
                        .confirmationDialog(roleDialog.title, isPresented: $showsHomeDialog, titleVisibility: .visible) {
                            roleActions(.home)
                        } message: {
                            if let message = roleDialog.message { Text(message) }
                        }

                        Button {
                            roleDialog = dialog(for: .work)
                            showsWorkDialog = true
                        } label: {
                            GlassIcon(systemName: isWork ? "briefcase.fill" : "briefcase",
                                      fill: isWork ? RoleColor.work : nil)
                        }
                        .accessibilityLabel(isWork ? "Remove as work station" : "Set as work station")
                        .accessibilityAddTraits(isWork ? .isSelected : [])
                        .confirmationDialog(roleDialog.title, isPresented: $showsWorkDialog, titleVisibility: .visible) {
                            roleActions(.work)
                        } message: {
                            if let message = roleDialog.message { Text(message) }
                        }
                    }

                    GlassCloseButton { dismiss() }
                }
            }
        }
    }

    /// With home and work both set, on either one's board: the way to the other.
    private var commute: (direction: CommuteDirection, toward: StationRole)? {
        guard let home = settings.homeCode, let work = settings.workCode, home != work else { return nil }
        if station.code == home { return CommuteDirection(from: home, toward: work).map { ($0, .work) } }
        if station.code == work { return CommuteDirection(from: work, toward: home).map { ($0, .home) } }
        return nil
    }

    private var isHome: Bool { settings.homeCode == station.code }
    private var isWork: Bool { settings.workCode == station.code }

    // MARK: Home and work dialogs

    fileprivate enum Role {
        case home, work
    }

    /// What tapping home or work would do: set this station, replace the one that's
    /// set, or remove this one.
    fileprivate struct RoleDialog {
        var title = ""
        var message: String?
        var confirm = ""
        var destructive = false
        /// What to save on confirming; nil removes it.
        var code: String?
    }

    private func dialog(for role: Role) -> RoleDialog {
        let current = role == .home ? settings.homeCode : settings.workCode
        let kind = role == .home ? "home" : "work"
        if current == station.code {
            return RoleDialog(title: "Remove \(station.name) as your \(kind) station?",
                              confirm: "Remove", destructive: true, code: nil)
        }
        if let current, let other = RailNetwork.shared.station(current) {
            return RoleDialog(title: "Replace your \(kind) station?",
                              message: "Your \(kind) station is \(other.name). \(station.name) will replace it.",
                              confirm: "Replace", code: station.code)
        }
        let button = role == .home ? "house" : "briefcase"
        return RoleDialog(title: "Make \(station.name) your \(kind) station?",
                          message: "The app uses your \(kind) station to choose the board it opens with, "
                              + "and the \(button) button on the map takes you straight to it.",
                          confirm: role == .home ? "Set as Home" : "Set as Work", code: station.code)
    }

    @ViewBuilder
    private func roleActions(_ role: Role) -> some View {
        let dialog = roleDialog
        Button(dialog.confirm, role: dialog.destructive ? ButtonRole.destructive : nil) {
            if role == .home {
                settings.setHome(dialog.code)
            } else {
                settings.setWork(dialog.code)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var roleColor: Color {
        switch (isHome, isWork) {
        case (true, false): return RoleColor.home
        case (false, true): return RoleColor.work
        default: return .secondary
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

    /// The board shows at least this many trains, from the timetable past the live ones.
    private static let minimumRows = 4

    /// What the timetable trains depend on: the station, the last live train (or,
    /// with none, the minute), and which way the board shows.
    private var laterKey: String {
        let last = model.snapshot.map { snapshot in
            Int((snapshot.rows.map(\.scheduled).max() ?? snapshot.fetchedAt).timeIntervalSince1970 / 60)
        }
        return "\(station.code)#\(last.map(String.init) ?? "-")#\(showsAllDirections)#\(commute?.direction.toward ?? "")"
    }

    // MARK: Below the board

    @ViewBuilder
    private func statusLine(addsTimetable: Bool) -> some View {
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Live · updated \(TorontoTime.clock(snapshot.fetchedAt))")
                        if addsTimetable {
                            Text("Later trains as timetabled, without platforms")
                                .foregroundStyle(.tertiary)
                        }
                    }
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
        .glass(.plain, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Home and work colours, as in Apple Maps: home blue, work brown. Used on the
/// map pins, the buttons, Settings, search and the trip sheet.
enum RoleColor {
    static let home = Color(uiColor: StationRole.home.uiColor)
    static let work = Color(uiColor: StationRole.work.uiColor)
}
