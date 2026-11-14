import SwiftUI
import UIKit

/// Bottom sheet for one station: name, lines and home/work toggles on glass, the
/// board right under them, so a few trains show even at half height. The day,
/// which way, and Get here sit in a bar at the bottom, where thumbs are, over the
/// board's soft edge. Tapping a train opens its stop list in another sheet.
struct StationSheet: View {
    let station: Station
    /// Its Get here button, tapped: the trip card to it (with the plan the button
    /// has made). Nil: no button.
    var onGetHere: ((TripPlan?) -> Void)? = nil

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
    /// The timetable's whole day picked in the day menu (nil while it loads).
    @State private var plannedRows: [BoardRow]?
    /// What the home or work button is about to do, asked first. Worked out when the
    /// button is tapped, so the words don't change while the dialog closes.
    @State private var roleDialog = RoleDialog()
    @State private var showsHomeDialog = false
    @State private var showsWorkDialog = false
    /// Bumped when the app comes back to the foreground, restarting the refresh loop
    /// so the board updates right away instead of waiting out the interval.
    @State private var wake = 0
    /// The trip here from where you are, for the Get here button (nil until made).
    @State private var getHere: TripPlan?
    #if DEBUG
    @State private var debugScroll = ScrollPosition(edge: .top)
    @State private var tappedGetHere = false
    #endif

    var body: some View {
        // A navigation stack only for the bar at the bottom: from iOS 26 it's the
        // system's toolbar, which needs one. Its own top bar stays hidden (the
        // header is ours), and its background clear, so the sheet's glass shows.
        NavigationStack {
            board
                .toolbarVisibility(.hidden, for: .navigationBar)
                .containerBackground(.clear, for: .navigation)
        }
    }

    @ViewBuilder
    private var board: some View {
        // On your home board only the trains toward work, on your work board only the
        // ones toward home, unless you ask for them all.
        let commute = self.commute
        let filter = showsAllDirections ? nil : commute?.direction
        let allRows = model.snapshot?.rows ?? []
        let live = filter.map { allRows.filter($0.includes) } ?? allRows
        // After the live trains (they run out within a few hours), the rest of today's
        // from the timetable; and never an empty board: on a quiet evening or weekend,
        // tomorrow's or Monday's first ones.
        let liveTrips = Set(allRows.map(\.tripNumber))
        let added = model.snapshot == nil ? [] : (filter.map { laterRows.filter($0.includes) } ?? laterRows)
            .filter { !liveTrips.contains($0.tripNumber) }
        // A later day picked in the day menu: the timetable's whole day.
        let chosen = BoardTime.shared.shownDay(at: Date())
        let planned = plannedRows.map { list in filter.map { list.filter($0.includes) } ?? list }
        let dayRows = chosen == nil ? live + added : planned ?? []
        // A long day narrows to its morning, noon or afternoon, among the parts with
        // trains. Only the board's own day counts (04:00 to 04:00: service runs past
        // midnight), not tomorrow's trains a live board lists at night.
        let calendar = BoardDay.calendar
        let dayStart = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: chosen ?? Date()) ?? Date()
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let ofTheDay = dayRows.filter { $0.scheduled >= dayStart && $0.scheduled < dayEnd }
        let parts = DayPeriod.parts.filter { part in ofTheDay.contains { part.contains($0.scheduled) } }
        let showsParts = ofTheDay.count > Self.partsAfter && parts.count > 1
        let part = showsParts && parts.contains(BoardTime.shared.period) ? BoardTime.shared.period : .allDay
        let rows = part == .allDay ? dayRows : ofTheDay.filter { part.contains($0.scheduled) }
        let earlier = earlierRows.map { list in (filter.map { list.filter($0.includes) } ?? list).filter { part.contains($0.scheduled) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    BoardView(
                        rows: rows,
                        station: station,
                        now: context.date,
                        message: chosen != nil
                            ? (planned == nil ? "Loading | Chargement" : "No trains that day | Aucun train ce jour-là")
                            : boardMessage ?? (rows.isEmpty && !allRows.isEmpty
                                ? commute.map { $0.toward == .work ? "No trains toward work | Aucun train vers le travail"
                                                                   : "No trains toward home | Aucun train vers la maison" }
                                : nil),
                        isLoading: chosen != nil ? planned == nil : model.snapshot == nil && model.errorMessage == nil,
                        isScheduled: chosen != nil || model.snapshot?.source == .schedule,
                        onSelectRow: { row in
                            selectedTrip = TripSelection(row: row, station: station, fromBoard: true)
                        },
                        earlierRows: chosen == nil ? earlier : nil,
                        onToggleEarlier: chosen == nil ? toggleEarlier : nil,
                        timetableRowIDs: chosen == nil ? Set(added.map(\.id)) : [],
                        chosenDay: chosen
                    )
                }
                statusLine(addsTimetable: !added.isEmpty, chosen: chosen)
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
        // The day, which way, and Get here: in the bar at the bottom.
        .modifier(BoardBar(
            chosen: chosen, parts: showsParts ? parts : [], part: part, toward: commute?.toward,
            showsAll: showsAllDirections, plan: getHerePlan,
            onSelectDay: { day in withAnimation(.snappy) { BoardTime.shared.day = day } },
            onSelectPart: { new in withAnimation(.snappy) { BoardTime.shared.period = new } },
            onToggleDirection: { withAnimation(.snappy) { showsAllDirections.toggle() } },
            onGetHere: { plan in onGetHere?(plan) }
        ))
        .environment(\.glassBackdrop, .sheet)
        // No pull-to-refresh: pulling down closes the sheet. The board keeps
        // itself current instead.
        // Paused while a trip sheet covers this board; resumes (and refreshes) when it closes.
        .task(id: "\(station.code)#\(wake)#\(selectedTrip == nil)") {
            guard selectedTrip == nil else { return }
            await model.run(station: station)
        }
        .task(id: "getHere#\(station.code)#\(wake)") {
            guard onGetHere != nil else { return }
            await planGetHere()
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
            plannedRows = nil
        }
        // The picked day's trains, worked out again for another station, day or way.
        .task(id: plannedKey) {
            guard let day = BoardTime.shared.shownDay(at: Date()) else {
                plannedRows = nil
                return
            }
            plannedRows = await BoardService.shared.dayRows(
                for: station, on: day, toward: showsAllDirections ? nil : commute?.direction)
        }
        // The timetable's trains after the live ones, worked out again when those move on.
        .task(id: laterKey) {
            guard let snapshot = model.snapshot else { return }
            let direction = showsAllDirections ? nil : commute?.direction
            let live = direction.map { snapshot.rows.filter($0.includes) } ?? snapshot.rows
            let after = max(snapshot.rows.map(\.scheduled).max() ?? .distantPast, Date())
            laterRows = await BoardService.shared.laterRows(
                for: station, after: after, atLeast: max(0, Self.minimumRows - live.count), toward: direction)
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

    // MARK: Get here

    /// The trip here for the Get here button: planned like a trip from search,
    /// now and every minute while the board is up (where you are only looked up
    /// again after 10 minutes). Never asks for your location (without it, from
    /// home, work or Union).
    private func planGetHere() async {
        var maxAge: TimeInterval = 120
        while !Task.isCancelled {
            let location = await LocationProvider.shared.locationIfAllowed(maxAge: maxAge)
            maxAge = 600
            let made = await TripPlanner.plan(to: PlanDestination(station: station), from: nil, on: nil,
                                              location: location, home: settings.homeCode,
                                              work: settings.workCode, now: AppClock.now)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { getHere = made }
            #if DEBUG
            // `-getHere YES`: tapped once it's there.
            if !tappedGetHere, DebugScene.current != nil, UserDefaults.standard.bool(forKey: "getHere"),
               GetHereButton.shows(made) {
                tappedGetHere = true
                try? await Task.sleep(for: .seconds(1.5))
                onGetHere?(made)
            }
            #endif
            try? await Task.sleep(for: .seconds(60))
        }
    }

    // MARK: The bar at the bottom

    /// The trip here for Get here, when the board has one to offer (see `planGetHere`).
    private var getHerePlan: TripPlan? {
        guard onGetHere != nil, let plan = getHere, plan.destination.station == station.code,
              GetHereButton.shows(plan) else { return nil }
        return plan
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
    /// With more trains than this in a day, it can narrow to a part of the day.
    private static let partsAfter = 10
    private var plannedKey: String {
        let day = BoardTime.shared.day.map(TorontoTime.dateWire) ?? "today"
        return "\(station.code)#\(day)#\(showsAllDirections)#\(commute?.direction.toward ?? "")"
    }

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
    private func statusLine(addsTimetable: Bool, chosen: Date?) -> some View {
        if chosen != nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "calendar")
                Text("As timetabled: no live times or platforms")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        } else if let snapshot = model.snapshot {
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

/// A board's bar at the bottom: the day it shows (on a busy one, the part of it
/// too) on the leading side; on the trailing side, under your thumb, which way on
/// your home or work board, and Get here, each a tap away. From iOS 26 it's the
/// system's bottom toolbar, which floats its glass where iOS puts it, concentric
/// with the screen's corners, over the board's soft scroll edge; Get here is its
/// one prominent action, at the trailing end. Before iOS 26, a bar of our own,
/// frosted.
private struct BoardBar: ViewModifier {
    let chosen: Date?
    let parts: [DayPeriod]
    let part: DayPeriod
    /// Home or work, on your home or work board (nil: no direction to pick).
    let toward: StationRole?
    let showsAll: Bool
    let plan: TripPlan?
    let onSelectDay: (Date?) -> Void
    let onSelectPart: (DayPeriod) -> Void
    let onToggleDirection: () -> Void
    let onGetHere: (TripPlan) -> Void

    #if DEBUG
    /// `-boardBarStyle own`: the bar of our own on iOS 26 too, to compare.
    private static let ownBarForced = UserDefaults.standard.string(forKey: "boardBarStyle") == "own"
    #else
    private static let ownBarForced = false
    #endif

    func body(content: Content) -> some View {
        if Self.ownBarForced {
            content.pinnedBottomBar { ownBar }
        } else if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .toolbar {
                    // With all three, the day is just its icon (the board's title names
                    // a later day), so which way keeps its words.
                    ToolbarItem(placement: .bottomBar) {
                        day(compact: toward != nil && plan != nil, chrome: false)
                    }
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    if let toward {
                        ToolbarItem(placement: .bottomBar) {
                            BoardDirectionButton(toward: toward, showsAll: showsAll, chrome: false,
                                                 toggle: onToggleDirection)
                        }
                    }
                    if let plan {
                        // (Text buttons each get their own glass.)
                        if toward != nil {
                            ToolbarSpacer(.fixed, placement: .bottomBar)
                        }
                        ToolbarItem(placement: .bottomBar) {
                            GetHereToolbarButton(plan: plan) { onGetHere(plan) }
                        }
                    }
                }
        } else {
            content.pinnedBottomBar { ownBar }
        }
    }

    private func day(compact: Bool, chrome: Bool) -> some View {
        BoardDayMenu(selected: chosen, now: Date(), parts: parts, part: part, compact: compact, chrome: chrome,
                     onSelectDay: onSelectDay, onSelectPart: onSelectPart)
    }

    /// Before iOS 26: glass-like capsules in a frosted bar. Where they don't all
    /// fit, the day goes to its icon first, then which way.
    private var ownBar: some View {
        func row(dayCompact: Bool, directionCompact: Bool) -> some View {
            HStack(spacing: 8) {
                day(compact: dayCompact, chrome: true)
                Spacer(minLength: 0)
                if let toward {
                    BoardDirectionButton(toward: toward, showsAll: showsAll, compact: directionCompact,
                                         toggle: onToggleDirection)
                }
                if let plan {
                    GetHereButton(plan: plan) { onGetHere(plan) }
                }
            }
        }
        return ViewThatFits(in: .horizontal) {
            row(dayCompact: false, directionCompact: false)
            row(dayCompact: true, directionCompact: false)
            row(dayCompact: true, directionCompact: true)
        }
    }
}

/// In the board's bottom bar: the day it shows ("Today", "Sat 14", with the part
/// of a busy day: "Today · Noon"), and in its menu the week ahead and the parts.
/// Compact, just its icon (and the part of the day, when it's narrowed to one).
struct BoardDayMenu: View {
    /// A later day at midnight; nil for today.
    let selected: Date?
    let now: Date
    /// The parts of the day it can narrow to (none: the whole day only).
    let parts: [DayPeriod]
    let part: DayPeriod
    var compact = false
    /// Its own glass capsule; without, the label alone (the system toolbar gives it glass).
    var chrome = true
    let onSelectDay: (Date?) -> Void
    let onSelectPart: (DayPeriod) -> Void

    var body: some View {
        Menu {
            Section("Day") {
                Picker("Day", selection: Binding(get: { selected }, set: onSelectDay)) {
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        Text(BoardDay.names(for: day, now: now).english)
                            .tag(index == 0 ? Date?.none : Date?.some(day))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if parts.count > 1 {
                Section("Time of day") {
                    Picker("Time of day", selection: Binding(get: { part }, set: onSelectPart)) {
                        Text(DayPeriod.allDay.label).tag(DayPeriod.allDay)
                        ForEach(parts, id: \.self) { part in
                            Text(part.label).tag(part)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                if !compact {
                    Text(title)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                } else if part != .allDay {
                    Text(part.label)
                        .lineLimit(1)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .modifier(BarCapsule(on: chrome, iconOnly: compact && part == .allDay))
        }
        // (White like the other buttons, not the accent a menu's label takes.)
        .tint(Color.primary)
        .fixedSize()
        .accessibilityLabel("Day: \(spoken)")
    }

    /// "Today", "Sat 14", and the part of the day when it's narrowed to one.
    private var title: String {
        let day = selected.map(Self.short.string(from:)) ?? "Today"
        return part == .allDay ? day : "\(day) · \(part.label)"
    }

    private var spoken: String {
        let day = selected.map { BoardDay.names(for: $0, now: now).english } ?? "Today"
        return part == .allDay ? day : "\(day), \(part.label)"
    }

    /// Today and the next `BoardTime.daysAhead` days, at midnight (as the trip card's week strip has them).
    private var days: [Date] {
        let calendar = BoardDay.calendar
        let today = calendar.startOfDay(for: now)
        return (0...BoardTime.daysAhead).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = TorontoTime.zone
        formatter.dateFormat = "EEE d"
        return formatter
    }()
}

/// In the board's bottom bar, on your home or work station's board: which way its
/// trains go ("Toward work"), or "All directions"; a tap switches. Just the icon
/// where the labels don't all fit.
struct BoardDirectionButton: View {
    let toward: StationRole
    let showsAll: Bool
    var compact = false
    /// Its own glass capsule; without, the label alone (the system toolbar gives it glass).
    var chrome = true
    let toggle: () -> Void

    var body: some View {
        let label = showsAll ? "All directions" : (toward == .work ? "Toward work" : "Toward home")
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: showsAll ? "arrow.left.arrow.right" : toward.symbolName)
                    .foregroundStyle(showsAll ? Color.primary : Color(uiColor: toward.uiColor))
                if !compact {
                    Text(label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .font(.subheadline.weight(.semibold))
            .modifier(BarCapsule(on: chrome, iconOnly: compact))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(showsAll ? "Showing trains in all directions" : "Showing trains \(label.lowercased())")
        .accessibilityHint(showsAll ? (toward == .work ? "Shows just the trains toward work" : "Shows just the trains toward home")
                                    : "Shows the trains in all directions")
    }
}

/// A bar button's own glass capsule, 44 points tall (a circle for an icon alone),
/// when it isn't in the system toolbar, which gives its items their glass. In
/// the toolbar, room either side within the glass it gives, which hugs a custom
/// label: about as much as our own capsule has.
private struct BarCapsule: ViewModifier {
    let on: Bool
    var iconOnly = false

    func body(content: Content) -> some View {
        if on {
            content
                .padding(.horizontal, iconOnly ? 0 : 14)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Capsule())
                .glass(.interactive, in: Capsule())
        } else {
            content
                .padding(.horizontal, iconOnly ? 0 : 8)
                .contentShape(Capsule())
        }
    }
}

/// Get here in the system's bottom toolbar: its one prominent action, in the
/// accent's green, on the trailing side (as the guidelines have a key action).
@available(iOS 26.0, *)
private struct GetHereToolbarButton: View {
    let plan: TripPlan
    let onTap: () -> Void

    var body: some View {
        let duration = plan.recommended.map { DurationText.text(from: AppClock.now, to: $0.arrivalThere) }
        let origin = plan.origin.flatMap(RailNetwork.shared.station)?.name
        Button(action: onTap) {
            // (Its words too: a toolbar shows a Label's icon alone.)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                Text("Get here")
            }
            .font(.subheadline.weight(.bold))
            // (As much room inside its glass as the others have.)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Color.accentColor)
        .accessibilityLabel(GetHereButton.detail(duration: duration, from: origin).map { "Get here, \($0)" } ?? "Get here")
        .accessibilityHint("Shows how to get here by train")
    }
}

/// Home and work colours, as in Apple Maps: home blue, work brown. Used on the
/// map pins, the buttons, Settings, search and the trip sheet.
enum RoleColor {
    static let home = Color(uiColor: StationRole.home.uiColor)
    static let work = Color(uiColor: StationRole.work.uiColor)
}

/// In a station's board's bottom bar: Get here, filling the room the day and the
/// direction leave. It opens the trip card here from where you are, with the
/// plan the board made (`StationSheet.planGetHere`); how long that takes, and
/// from where ("36 min from Port Credit"), VoiceOver says.
struct GetHereButton: View {
    let plan: TripPlan
    let onTap: () -> Void

    private let network = RailNetwork.shared

    var body: some View {
        let duration = plan.recommended.map { DurationText.text(from: AppClock.now, to: $0.arrivalThere) }
        let origin = plan.origin.flatMap(network.station)?.name
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Get here")
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(.tinted(Color.accentColor.opacity(0.3)), in: Capsule())
        .accessibilityLabel(Self.detail(duration: duration, from: origin).map { "Get here, \($0)" } ?? "Get here")
        .accessibilityHint("Shows how to get here by train")
    }

    /// Only when getting there by train makes sense: not when you're there, or it's
    /// the station nearest you (you'd just go there), or there's no timetable.
    static func shows(_ plan: TripPlan) -> Bool {
        shows(isThere: plan.isThere, isNearest: plan.isNearest, noTimetable: plan.noTimetable)
    }

    static func shows(isThere: Bool, isNearest: Bool, noTimetable: Bool) -> Bool {
        !isThere && !isNearest && !noTimetable
    }

    /// "36 min from Port Credit" (getting there now, from the station you'd set
    /// off from), "From Port Credit" when no train soon is the one to take, nil
    /// with no station to start from.
    static func detail(duration: String?, from origin: String?) -> String? {
        guard let origin else { return nil }
        guard let duration else { return "From \(origin)" }
        return "\(duration) from \(origin)"
    }

    /// The accent's green, light on dark and dark on light so it reads on the glass.
    private static let labelColor = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.77, green: 0.93, blue: 0.48, alpha: 1)
            : UIColor(red: 0.29, green: 0.45, blue: 0.04, alpha: 1)
    })
}
