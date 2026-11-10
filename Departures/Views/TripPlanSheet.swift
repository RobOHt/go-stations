import CoreLocation
import SwiftUI

/// A trip being planned to somewhere picked in search: where it starts, the day,
/// the trips that day, and which one the map shows. RootView keeps it, so the map
/// can draw the trip while the card is up.
@MainActor
@Observable
final class TripPlanModel: Identifiable {
    let id = UUID()
    let destination: PlanDestination
    /// The station picked to start from; nil for the fastest from where you are.
    private(set) var origin: String?
    /// A later day picked on the week strip; nil for today.
    private(set) var day: Date?
    private(set) var plan: TripPlan?
    private(set) var isPlanning = false
    /// The trip opened in the list, and drawn on the map (nil: the recommended one,
    /// or the first, is drawn).
    var openID: String?
    /// The card's question about the recommended trip: asking, turned down, then
    /// (once a trip is tracked) asking about alerts, and done.
    var stage: Stage = .offer
    /// Fetching the first train's stops to start tracking.
    private(set) var isStartingToTrack = false

    enum Stage: Equatable {
        case offer, declined, alerts, done
    }

    @ObservationIgnored private let home: String?
    @ObservationIgnored private let work: String?
    @ObservationIgnored private var planning: Task<Void, Never>?

    init(destination: PlanDestination, home: String?, work: String?) {
        self.destination = destination
        self.home = home
        self.work = work
    }

    func start() {
        replan()
    }

    func pickOrigin(_ code: String?) {
        guard code != origin else { return }
        origin = code
        openID = nil
        replan()
    }

    func pickDay(_ newDay: Date?) {
        guard newDay != day else { return }
        day = newDay
        openID = nil
        replan()
    }

    private func replan() {
        planning?.cancel()
        isPlanning = true
        let destination = self.destination, origin = self.origin, day = self.day, home = self.home, work = self.work
        planning = Task { [weak self] in
            let location = await LocationProvider.shared.currentLocation(maxAge: 120)
            let plan = await TripPlanner.plan(to: destination, from: origin, on: day, location: location,
                                              home: home, work: work, now: AppClock.now)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.snappy) {
                self.plan = plan
                self.isPlanning = false
            }
        }
    }

    /// The trip on the map: the one opened in the list, else the recommended one,
    /// else the first.
    var shown: Journey? {
        guard let plan else { return nil }
        if let openID, let open = plan.journeys.first(where: { $0.id == openID }) { return open }
        return plan.recommended ?? plan.journeys.first
    }

    /// Whether a trip can be tracked now: today, not gone, leaving within a few
    /// hours (a Live Activity lasts about eight).
    func canTrack(_ journey: Journey, at now: Date) -> Bool {
        guard plan?.isToday == true else { return false }
        let wait = journey.departure.timeIntervalSince(now)
        return wait > -60 && wait <= TripPlanner.trackAhead
    }

    func isTracking(_ journey: Journey) -> Bool {
        TripTracker.shared.trip?.journeyKey == journey.id
    }

    /// Starts tracking a trip (its first train's stops live, when Metrolinx has
    /// them), then asks about alerts.
    func track(_ journey: Journey) async {
        guard let first = journey.legs.first, let row = TripPlanner.row(for: first),
              let station = RailNetwork.shared.station(first.boardCode) else { return }
        isStartingToTrack = true
        let detail = await BoardService.shared.tripDetail(for: row, from: station)
        isStartingToTrack = false
        TripTracker.shared.track(journey, row: row, detail: detail)
        withAnimation(.snappy) { stage = .alerts }
    }

    /// The answer to "you'll be notified…": OK turns alerts on for this trip (and
    /// asks iOS for them), or none for this trip.
    func answerAlerts(_ wanted: Bool) async {
        TripTracker.shared.setAlerts(wanted)
        if wanted { await TripAlerts.shared.requestPermission() }
        stage = .done
    }
}

/// The trip card, from search: "To Union Station", where it starts (the station
/// you'd get there soonest from, or one you pick), a week strip like the boards',
/// and the day's trips with their changes. Today, near enough to set off, it
/// offers the trip you'd make: "This trip will get you to Union Station in 1 h 5
/// min", track it or not; tracking it then asks about alerts. The map shows the
/// trip opened in the list (or the one offered), the rest of the network dimmed.
struct TripPlanSheet: View {
    @Bindable var model: TripPlanModel
    let onClose: () -> Void

    @Environment(AppSettings.self) private var settings
    @State private var showsStationPicker = false

    private let network = RailNetwork.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DayStrip(selected: model.day, now: AppClock.now) { day in
                    model.pickDay(day)
                }
                content
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .pinnedHeader { header }
        .environment(\.glassBackdrop, .sheet)
        .sheet(isPresented: $showsStationPicker) {
            StationPicker { code in model.pickOrigin(code) }
        }
        .onChange(of: model.stage) { _, stage in
            // Asked and answered: back to the map, and the train.
            if stage == .done { onClose() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("To \(model.destination.name)")
                    .font(.title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                originMenu
            }
            .padding(.top, PinnedHeaderMetrics.textTop)

            Spacer(minLength: 8)

            GlassCloseButton { onClose() }
        }
    }

    /// "From Oakville · 6 min walk", which opens the choice of where to start.
    private var originMenu: some View {
        Menu {
            Button {
                model.pickOrigin(nil)
            } label: {
                Label("Fastest from where you are", systemImage: "location.fill")
            }
            if let home = settings.homeCode.flatMap(network.station), home.code != model.destination.station {
                Button {
                    model.pickOrigin(home.code)
                } label: {
                    Label("Home: \(home.name)", systemImage: "house.fill")
                }
            }
            if let work = settings.workCode.flatMap(network.station), work.code != model.destination.station {
                Button {
                    model.pickOrigin(work.code)
                } label: {
                    Label("Work: \(work.name)", systemImage: "briefcase.fill")
                }
            }
            Button {
                showsStationPicker = true
            } label: {
                Label("Another station…", systemImage: "magnifyingglass")
            }
        } label: {
            HStack(spacing: 4) {
                Text(originText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .contentShape(Rectangle())
        }
        .accessibilityHint("Picks the station the trip starts from")
    }

    private var originText: String {
        guard let plan = model.plan else { return "From…" }
        guard let origin = plan.origin, let station = network.station(origin) else {
            return plan.isThere ? "Start from another station" : "Pick a station to start from"
        }
        guard let start = plan.start else { return "From \(station.name)" }
        let getting = start.onFoot ? "\(DurationText.text(minutes: start.minutes)) walk"
                                   : "\(DurationText.text(minutes: start.minutes)) drive"
        return "From \(station.name) · \(getting)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let plan = model.plan {
            if plan.noTimetable {
                note("No timetable yet", systemImage: "calendar.badge.exclamationmark",
                     detail: "Trips show once the timetable has loaded.")
            } else if plan.isThere {
                note("You're there", systemImage: "mappin.and.ellipse",
                     detail: "\(model.destination.name) is a short walk from where you are. To plan from somewhere else, pick a station above.")
            } else if plan.origin == nil || plan.origin == model.destination.station {
                note("Pick a station to start from", systemImage: "tram.fill",
                     detail: "Tap “From” above.")
            } else {
                switch model.stage {
                case .alerts, .done:
                    alertsCard
                case .offer:
                    if let recommended = plan.recommended {
                        offerCard(recommended)
                    }
                case .declined:
                    EmptyView()
                }
                trips(plan)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
        }
    }

    private func note(_ title: String, systemImage: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: The offer, and alerts

    /// "This trip will get you to Union Station in 1 h 5 min": take it?
    private func offerCard(_ journey: Journey) -> some View {
        let now = AppClock.now
        let color = lineColor(journey.legs[0].lineCode)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Leave now", systemImage: "figure.walk.departure")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
            Text("This trip will get you to \(model.destination.name) in \(DurationText.text(from: now, to: journey.arrivalThere)), at \(TorontoTime.hourMinute(journey.arrivalThere)).")
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            JourneySummary(journey: journey, destination: model.destination)
            Text("Would you like to take this trip?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    Task { await model.track(journey) }
                } label: {
                    Group {
                        if model.isStartingToTrack {
                            ProgressView().tint(.white)
                        } else {
                            Label("Track", systemImage: "train.side.front.car")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(.tinted(color), in: Capsule())
                .disabled(model.isStartingToTrack)
                .accessibilityHint("Follows this trip on the map and in a Live Activity")

                Button {
                    withAnimation(.snappy) { model.stage = .declined }
                } label: {
                    Text("Don't track")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(.interactive, in: Capsule())
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Once a trip is tracked: what you'll be told, and whether you want it.
    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tracking this trip", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("If you board a tracked train, you'll be notified before it leaves, before your connections, and before your stop.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    Task { await model.answerAlerts(true) }
                } label: {
                    Text("OK")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(.tinted(.accentColor), in: Capsule())

                Button {
                    Task { await model.answerAlerts(false) }
                } label: {
                    Text("Don't notify me for this trip")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glass(.interactive, in: Capsule())
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: The day's trips

    private func trips(_ plan: TripPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dayTitle(plan))
                    .font(.headline)
                if model.isPlanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            if plan.journeys.isEmpty {
                Text(plan.isToday ? "No more trains there today. Pick another day above."
                                  : "No trains there that day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            LazyVStack(spacing: 8) {
                ForEach(plan.journeys) { journey in
                    journeyCard(journey, plan: plan)
                }
            }
            Text("Timetable times, with at least 5 minutes for each change.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
        }
    }

    private func dayTitle(_ plan: TripPlan) -> String {
        if plan.isToday { return "Trips today" }
        guard let start = CommutePlanner.Clock.start(of: plan.day) else { return "Trips" }
        // Midday, safely inside the day whatever the clocks do.
        return "Trips on \(BoardDay.names(for: start.addingTimeInterval(12 * 3600), now: AppClock.now).english)"
    }

    private func journeyCard(_ journey: Journey, plan: TripPlan) -> some View {
        let isOpen = model.openID == journey.id
        let isShown = model.shown?.id == journey.id
        // Leaves before you could be at the station.
        let tooSoon = plan.readyAt.map { journey.departure < $0 } ?? false
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { model.openID = isOpen ? nil : journey.id }
            } label: {
                JourneySummary(journey: journey, destination: model.destination,
                               badge: journey.id == plan.recommended?.id ? "Best" : nil,
                               note: tooSoon ? "Leaves before you'd get there" : nil,
                               isTracking: model.isTracking(journey))
                    .opacity(tooSoon && !isOpen ? 0.55 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides its stops" : "Shows this trip on the map")

            if isOpen {
                JourneyStops(journey: journey, destination: model.destination)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                if model.isTracking(journey) {
                    Label("Tracking this trip", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                } else if model.canTrack(journey, at: AppClock.now) {
                    Button {
                        Task { await model.track(journey) }
                    } label: {
                        Label("Track this trip", systemImage: "train.side.front.car")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glass(.tinted(lineColor(journey.legs[0].lineCode)), in: Capsule())
                    .disabled(model.isStartingToTrack)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            // The one on the map.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isShown ? lineColor(journey.legs[0].lineCode) : .clear, lineWidth: 2)
        }
    }

    private func lineColor(_ code: String) -> Color {
        network.line(code: code)?.color ?? .gray
    }
}

// MARK: - One trip

/// A trip in a line: when it leaves and gets in, how long it takes, its lines,
/// and where it changes ("Change at Union").
struct JourneySummary: View {
    let journey: Journey
    let destination: PlanDestination
    var badge: String? = nil
    var note: String? = nil
    var isTracking = false

    private let network = RailNetwork.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(TorontoTime.hourMinute(journey.departure)) – \(TorontoTime.hourMinute(journey.arrival))")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                if isTracking {
                    Image(systemName: "location.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Tracking")
                }
                Spacer(minLength: 8)
                Text(DurationText.text(from: journey.departure, to: journey.arrivalThere))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.tertiary)
                    }
                    LineBadge(code: network.line(code: leg.lineCode)?.code ?? leg.lineCode)
                }
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, 3)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func name(_ code: String) -> String {
        TripActivityController.shortName(network.station(code)?.name ?? code)
    }

    /// "Direct", or "Change at Union", and the last bit to a place.
    private var summary: String {
        var text = journey.changes == 0 ? "Direct" : "Change at \(journey.changeCodes.map(name).joined(separator: ", "))"
        if journey.onwardMinutes > 0 {
            text += " · then \(DurationText.text(minutes: journey.onwardMinutes)) \(journey.onwardOnFoot ? "walk" : "by car")"
        }
        return text
    }
}

/// A trip's trains one under another: where you get on each and when, its line
/// and where it goes, how many stops, where you get off, and the time to change.
struct JourneyStops: View {
    let journey: Journey
    let destination: PlanDestination

    private let network = RailNetwork.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
                if index > 0 {
                    let wait = DurationText.text(from: journey.legs[index - 1].arrival, to: leg.departure)
                    Label("Change trains · \(wait) to make it", systemImage: "arrow.triangle.swap")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 62)
                        .padding(.vertical, 8)
                }
                legView(leg)
            }
            if journey.onwardMinutes > 0 {
                Label(onward, systemImage: journey.onwardOnFoot ? "figure.walk" : "car.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 62)
                    .padding(.top, 8)
            }
        }
    }

    /// The last bit, from the station to a place.
    private var onward: String {
        let minutes = DurationText.text(minutes: journey.onwardMinutes)
        return "\(minutes) \(journey.onwardOnFoot ? "walk" : "by car or bus") to \(destination.name)"
    }

    private func legView(_ leg: Journey.Leg) -> some View {
        let line = network.line(code: leg.lineCode)
        let color = line?.color ?? .gray
        let terminus = network.station(leg.terminusCode)?.name ?? leg.terminusCode
        let stops = leg.stopsBetween == 0 ? "no stops" : leg.stopsBetween == 1 ? "1 stop" : "\(leg.stopsBetween) stops"
        let ride = DurationText.text(from: leg.departure, to: leg.arrival)
        let about = "To \(terminus) · \(stops) · \(ride)"
        return VStack(alignment: .leading, spacing: 0) {
            stop(leg.departure, leg.boardCode, color: color)
            HStack(spacing: 0) {
                Capsule()
                    .fill(color)
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, 52 + 10 + 4)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        LineBadge(code: line?.code ?? leg.lineCode)
                        Text(line?.name ?? leg.lineCode)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(about)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.leading, 14)
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            stop(leg.arrival, leg.alightCode, color: color)
        }
    }

    private func stop(_ time: Date, _ code: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(TorontoTime.hourMinute(time))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .frame(width: 52, alignment: .trailing)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(color, lineWidth: 3.5))
                .frame(width: 14, height: 14)
            Text(network.station(code)?.name ?? code)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }
}

// MARK: - Picking where to start

/// Every station, to search, for where a trip starts.
private struct StationPicker: View {
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let network = RailNetwork.shared

    private var stations: [Station] {
        let text = query.trimmed.lowercased()
        var seen: Set<String> = []
        return network.stations
            .filter { seen.insert($0.code).inserted }
            .filter { text.isEmpty || $0.name.lowercased().contains(text) || $0.code.lowercased() == text }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmed.isEmpty {
                    Button {
                        onPick(nil)
                        dismiss()
                    } label: {
                        Label("Fastest from where you are", systemImage: "location.fill")
                    }
                }
                ForEach(stations) { station in
                    Button {
                        onPick(station.code)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Text(station.name)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            HStack(spacing: 3) {
                                ForEach(station.lineCodes.prefix(3), id: \.self) { LineBadge(code: $0) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station")
            .autocorrectionDisabled()
            .navigationTitle("Start from")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
