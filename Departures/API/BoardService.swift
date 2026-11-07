import Foundation

/// Builds a station's departure board from the Metrolinx API.
///
/// * Union Station uses the dedicated Union departures feed (the same data as the
///   physical board: platforms, "Express To" stop lists), merged with NextService
///   for live delays.
/// * Other stations use NextService plus each trip's stop list (cached per day)
///   for the Stops column, express detection and platform fallback.
/// * Cancellations come from the train exceptions feed; reasons from service alerts.
actor BoardService {
    static let shared = BoardService()

    struct TripStop: Sendable {
        let code: String
        let track: String?
    }

    private var tripCache: [String: [TripStop]] = [:]
    private var tripMisses: [String: Date] = [:]
    private var tripCacheDay = ""

    /// Live board, or the timetable when live data can't be had.
    func board(for station: Station) async throws -> BoardSnapshot {
        do {
            return try await liveBoard(for: station)
        } catch {
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw error }
            if let scheduled = await scheduledBoard(for: station, liveError: error) { return scheduled }
            throw error
        }
    }

    private func liveBoard(for station: Station) async throws -> BoardSnapshot {
        let client = MetrolinxClient()
        let network = RailNetwork.shared
        let now = Date()

        async let nextTask: Result<NextServiceResponse, Error> = client.result("/Stop/NextService/\(station.code)")
        async let exceptionsTask: Result<ExceptionsResponse, Error> = client.result("/ServiceUpdate/Exceptions/Train")
        async let alertsTask: Result<AlertsResponse, Error> = client.result("/ServiceUpdate/ServiceAlert/All")

        var unionTrips: [UnionDeparturesResponse.Trip] = []
        if station.isUnion {
            let union: Result<UnionDeparturesResponse, Error> = await client.result("/ServiceUpdate/UnionDepartures/All")
            if case .success(let response) = union {
                unionTrips = response.allDepartures?.trip ?? []
            }
        }

        let nextResult = await nextTask
        let exceptions = try? (await exceptionsTask).get()
        let alerts = try? (await alertsTask).get()

        var rows: [BoardRow]
        if !unionTrips.isEmpty {
            rows = Self.unionRows(unionTrips, next: try? nextResult.get(), network: network, now: now)
        } else {
            let next = try nextResult.get()
            rows = await stationRows(next, station: station, client: client, network: network, now: now)
        }

        let cancelled = Self.cancelledTrips(exceptions, stationCode: station.code)
        let reasons = Self.tripReasons(alerts)
        for index in rows.indices {
            if cancelled.contains(rows[index].tripNumber) {
                rows[index].isCancelled = true
            }
            if rows[index].isCancelled, let reason = reasons[rows[index].tripNumber] {
                rows[index].reasonEnglish = reason.english
                rows[index].reasonFrench = reason.french
            }
        }

        return BoardSnapshot(
            rows: rows,
            alerts: Self.stationAlerts(alerts, station: station, network: network),
            fetchedAt: now
        )
    }

    // MARK: Timetable fallback

    private func scheduledBoard(for station: Station, liveError: Error) async -> BoardSnapshot? {
        let now = Date()
        guard let departures = await ScheduleStore.shared.departures(from: station.code, after: now, limit: 16) else {
            return nil
        }
        let rows = departures.map { Self.row(for: $0, at: station) }
        let reason = (liveError as? LocalizedError)?.errorDescription ?? liveError.localizedDescription
        return BoardSnapshot(rows: rows, alerts: [], fetchedAt: now, source: .schedule, note: reason)
    }

    /// The trains that most recently left a station, oldest first, from the timetable.
    func earlierRows(for station: Station) async -> [BoardRow] {
        let departures = await ScheduleStore.shared.earlierDepartures(from: station.code, before: Date(), limit: 6) ?? []
        return departures.map { Self.row(for: $0, at: station) }
    }

    /// A board row for a timetable departure.
    /// A running train as a board row at one of its stops (the next one, say), so
    /// its stops can be opened like any train's.
    static func row(for trip: ScheduleStore.RunningTrip, at stopIndex: Int) -> BoardRow? {
        guard trip.pattern.indices.contains(stopIndex), stopIndex < trip.times.count,
              let station = RailNetwork.shared.station(trip.pattern[stopIndex])
        else { return nil }
        let departure = ScheduleStore.Departure(tripNumber: trip.tripNumber, lineCode: trip.lineCode,
                                                pattern: trip.pattern, stopIndex: stopIndex,
                                                time: trip.times[stopIndex], serviceDay: trip.serviceDay)
        return row(for: departure, at: station)
    }

    private static func row(for departure: ScheduleStore.Departure, at station: Station) -> BoardRow {
        let network = RailNetwork.shared
        let line = network.line(code: departure.lineCode)
        let code = line?.code ?? departure.lineCode
        let name = line?.name ?? code
        let onward = Array(departure.pattern[(departure.stopIndex + 1)...])
        // Union's board shows the line in the "To" column; other stations show the terminus.
        let destination = station.isUnion ? name : (onward.last.flatMap { network.station($0)?.name } ?? name)
        return BoardRow(
            tripNumber: departure.tripNumber,
            lineCode: code,
            lineName: name,
            destination: destination,
            stops: onward.compactMap { network.station($0)?.name },
            scheduled: departure.time,
            expected: departure.time,
            platform: nil,
            isExpress: network.isExpress(lineCode: code, stops: Array(departure.pattern[departure.stopIndex...])),
            isCancelled: false,
            reasonEnglish: nil,
            reasonFrench: nil,
            serviceDay: departure.serviceDay
        )
    }

    // MARK: One trip, stop by stop

    /// Every stop of the trip behind a board row: live times when Metrolinx has them,
    /// otherwise the timetable, otherwise just the stop names from the board.
    func tripDetail(for row: BoardRow, from station: Station) async -> TripDetail {
        let days = Self.serviceDays(for: row)
        let client = MetrolinxClient()
        for day in days {
            let response: TripStatusResponse? = try? await client.fetch("/Schedule/Trip/\(day)/\(row.tripNumber)")
            if let stops = response?.trips?.first?.stops,
               let detail = Self.liveDetail(Self.inCallingOrder(stops), row: row, station: station) {
                return detail
            }
        }

        for day in days {
            guard let trip = await ScheduleStore.shared.trip(number: row.tripNumber, serviceDay: day) else { continue }
            let stops = zip(trip.pattern, trip.times).enumerated().map { index, pair in
                TripDetail.Stop(index: index, code: pair.0, time: pair.1, expected: nil, platform: nil)
            }
            return TripDetail(stops: stops, source: .schedule)
        }

        // Names only: the station itself plus the stops the board listed.
        let network = RailNetwork.shared
        let onward = row.stops.compactMap { name in network.stations.first { $0.name == name.withoutGOSuffix }?.code }
        let codes = [station.code] + onward
        let stops = codes.enumerated().map { index, code in
            TripDetail.Stop(index: index, code: code, time: index == 0 ? row.scheduled : nil, expected: nil, platform: nil)
        }
        return TripDetail(stops: stops, source: nil)
    }

    private static func serviceDays(for row: BoardRow) -> [String] {
        if let day = row.serviceDay { return [day] }
        let day = TorontoTime.dateWire(row.scheduled)
        // After midnight the trip may belong to yesterday's service day: try that first.
        if TorontoTime.hour(row.scheduled) < 4 {
            return [TorontoTime.dateWire(row.scheduled.addingTimeInterval(-86_400)), day]
        }
        return [day]
    }

    /// The trip's stops in the order the train calls at them. Schedule/Trip's own
    /// order can't be trusted past midnight: it has listed stops by time of day,
    /// after-midnight ones first, and has written the same night both as "24:05"
    /// and "00:05" (a stop with a live time) in one list. So: by time of day, then
    /// from just after the longest wait round the clock (the night between the last
    /// stop and the first). Left as they are when a stop has no time.
    static func inCallingOrder(_ stops: [TripStatusResponse.Stop]) -> [TripStatusResponse.Stop] {
        let minutes = stops.map { clockMinutes($0.departureTime?.scheduled?.nonEmpty ?? $0.arrivalTime?.scheduled?.nonEmpty) }
        guard stops.count >= 2, minutes.allSatisfy({ $0 != nil }) else { return stops }
        let times = minutes.map { $0 ?? 0 }
        // By time of day (stops at the same minute keep Metrolinx's order)...
        let order = stops.indices.sorted { a, b in times[a] != times[b] ? times[a] < times[b] : a < b }
        // ...from just after the longest wait round the clock.
        var longest = -1
        var start = 0
        for position in order.indices {
            var gap = (times[order[(position + 1) % order.count]] - times[order[position]] + 1440) % 1440
            if position == order.count - 1, gap == 0 { gap = 1440 }
            if gap > longest {
                longest = gap
                start = (position + 1) % order.count
            }
        }
        return (order[start...] + order[..<start]).map { stops[$0] }
    }

    /// Minutes past midnight of a bare "HH:MM" time, 0 to 1439 ("24:05", 00:05 the
    /// next morning, is 5, as "00:05" is).
    static func clockMinutes(_ text: String?) -> Int? {
        guard let parts = text?.trimmed.split(separator: ":"), parts.count >= 2,
              let hours = Int(parts[0]), let mins = Int(parts[1].prefix(2)) else { return nil }
        return (hours * 60 + mins) % 1440
    }

    /// Schedule/Trip gives bare "HH:MM" times, so place every stop relative to the
    /// board row's own departure time at `station`.
    private static func liveDetail(_ stops: [TripStatusResponse.Stop], row: BoardRow, station: Station) -> TripDetail? {
        // Past midnight, Metrolinx writes "24:05" or "00:05" for the same time: count
        // from midnight either way, and on into the next day below.
        let minutes = clockMinutes

        let network = RailNetwork.shared
        let kept = stops.filter { $0.code.flatMap { network.station($0) } != nil }
        guard kept.count >= 2, let anchor = kept.firstIndex(where: { $0.code == station.code }) else { return nil }

        // Scheduled minutes along the trip, kept increasing across midnight.
        var scheduled: [Int?] = []
        var dayOffset = 0
        var last: Int?
        for stop in kept {
            guard var value = minutes(stop.departureTime?.scheduled?.nonEmpty ?? stop.arrivalTime?.scheduled?.nonEmpty) else {
                scheduled.append(nil)
                continue
            }
            value += dayOffset
            if let last, value < last - 360 {
                dayOffset += 1440
                value += 1440
            }
            last = value
            scheduled.append(value)
        }
        guard let anchorMinutes = scheduled[anchor] else { return nil }

        let result = kept.enumerated().map { index, stop -> TripDetail.Stop in
            let time = scheduled[index].map { row.scheduled.addingTimeInterval(TimeInterval(($0 - anchorMinutes) * 60)) }
            var expected: Date?
            if let time,
               let planned = minutes(stop.departureTime?.scheduled?.nonEmpty ?? stop.arrivalTime?.scheduled?.nonEmpty),
               let computed = minutes(stop.departureTime?.computed?.nonEmpty ?? stop.arrivalTime?.computed?.nonEmpty) {
                var delta = computed - planned
                if delta < -720 { delta += 1440 }
                if delta > 720 { delta -= 1440 }
                expected = time.addingTimeInterval(TimeInterval(delta * 60))
            }
            let platform = formatPlatform(stop.track?.actual) ?? formatPlatform(stop.track?.scheduled)
            return TripDetail.Stop(index: index, code: stop.code ?? "", time: time, expected: expected, platform: platform)
        }
        return TripDetail(stops: result, source: .live)
    }

    // MARK: Union Station

    private static func unionRows(_ trips: [UnionDeparturesResponse.Trip],
                                  next: NextServiceResponse?,
                                  network: RailNetwork,
                                  now: Date) -> [BoardRow] {
        var nextByTrip: [String: NextServiceResponse.Line] = [:]
        for line in next?.nextService?.lines ?? [] {
            if let trip = line.tripNumber?.nonEmpty, nextByTrip[trip] == nil {
                nextByTrip[trip] = line
            }
        }

        var seen = Set<String>()
        var rows: [BoardRow] = []
        for trip in trips where (trip.serviceType?.trimmed ?? "T") == "T" {
            guard let number = trip.tripNumber?.nonEmpty,
                  let scheduled = TorontoTime.parse(trip.time),
                  !seen.contains(number)
            else { continue }

            let live = nextByTrip[number]
            let expected = TorontoTime.parse(live?.computedDepartureTime) ?? scheduled
            guard expected > now.addingTimeInterval(-45) else { continue }
            seen.insert(number)

            let names = (trip.stops ?? []).compactMap { $0.name?.nonEmpty }
            let isExpress = names.first?.lowercased().hasPrefix("express") ?? false
            let stops = names.filter { !$0.lowercased().hasPrefix("express") }

            let serviceName = trip.service?.trimmed ?? ""
            let line = network.line(named: serviceName)
                ?? live.flatMap { network.line(code: $0.lineCode ?? "") }
            let code = line?.code ?? network.displayLineCode(apiCode: live?.lineCode ?? "")
            let name = line?.name ?? (serviceName.isEmpty ? code : serviceName)

            rows.append(BoardRow(
                tripNumber: number,
                lineCode: code,
                lineName: name,
                destination: name,
                stops: stops,
                scheduled: scheduled,
                expected: expected,
                platform: formatPlatform(trip.platform) ?? formatPlatform(live?.actualPlatform),
                isExpress: isExpress,
                isCancelled: live?.departureStatus?.trimmed == "C",
                reasonEnglish: nil,
                reasonFrench: nil
            ))
        }
        rows.sort { $0.scheduled < $1.scheduled }
        return Array(rows.prefix(18))
    }

    // MARK: Other stations

    private func stationRows(_ next: NextServiceResponse,
                             station: Station,
                             client: MetrolinxClient,
                             network: RailNetwork,
                             now: Date) async -> [BoardRow] {
        struct Draft {
            let line: NextServiceResponse.Line
            let trip: String
            let scheduled: Date
            let expected: Date
        }

        var seen = Set<String>()
        var drafts: [Draft] = []
        for line in next.nextService?.lines ?? [] where (line.serviceType?.trimmed ?? "T") == "T" {
            guard let trip = line.tripNumber?.nonEmpty,
                  !seen.contains(trip),
                  let scheduled = TorontoTime.parse(line.scheduledDepartureTime)
            else { continue }
            let expected = TorontoTime.parse(line.computedDepartureTime) ?? scheduled
            guard expected > now.addingTimeInterval(-45) else { continue }
            seen.insert(trip)
            drafts.append(Draft(line: line, trip: trip, scheduled: scheduled, expected: expected))
        }
        drafts.sort { $0.scheduled < $1.scheduled }
        drafts = Array(drafts.prefix(14))

        let stopsByTrip = await tripStops(for: drafts.map { (trip: $0.trip, date: $0.scheduled) }, client: client)

        return drafts.map { draft in
            let code = network.displayLineCode(apiCode: draft.line.lineCode ?? "")
            let lineName = network.line(code: code)?.name ?? draft.line.lineName?.trimmed ?? code

            let tripStops = stopsByTrip[draft.trip] ?? []
            let here = tripStops.firstIndex { $0.code == station.code }
            let after: [TripStop] = here.map { Array(tripStops[($0 + 1)...]) } ?? []
            let afterStations = after.filter { network.station($0.code) != nil }
            let stopCodes = [station.code] + afterStations.map(\.code)

            let destination = Self.destination(from: draft.line.directionName)
                ?? afterStations.last.flatMap { network.station($0.code)?.name }
                ?? lineName

            let platform = formatPlatform(draft.line.actualPlatform)
                ?? formatPlatform(draft.line.scheduledPlatform)
                ?? formatPlatform(here.flatMap { tripStops[$0].track })

            return BoardRow(
                tripNumber: draft.trip,
                lineCode: code,
                lineName: lineName,
                destination: destination,
                stops: afterStations.compactMap { network.station($0.code)?.name },
                scheduled: draft.scheduled,
                expected: draft.expected,
                platform: platform,
                isExpress: network.isExpress(lineCode: code, stops: stopCodes),
                isCancelled: draft.line.departureStatus?.trimmed == "C",
                reasonEnglish: nil,
                reasonFrench: nil
            )
        }
    }

    /// "LW - Aldershot GO" -> "Aldershot"
    private static func destination(from directionName: String?) -> String? {
        guard let name = directionName, let range = name.range(of: " - ") else { return nil }
        return String(name[range.upperBound...]).withoutGOSuffix.nonEmpty
    }

    /// Stop lists don't change during the day, so each trip is fetched once.
    private func tripStops(for trips: [(trip: String, date: Date)],
                           client: MetrolinxClient) async -> [String: [TripStop]] {
        let today = TorontoTime.dateWire(Date())
        if tripCacheDay != today || tripCache.count > 600 {
            tripCache.removeAll()
            tripMisses.removeAll()
            tripCacheDay = today
        }

        var result: [String: [TripStop]] = [:]
        var missing: [(trip: String, key: String, dates: [String])] = []
        for (trip, date) in trips {
            let day = TorontoTime.dateWire(date)
            let key = "\(day)|\(trip)"
            if let cached = tripCache[key] {
                result[trip] = cached
                continue
            }
            // Don't hammer the API for trips Schedule/Trip doesn't know (e.g. override trips).
            if let miss = tripMisses[key], Date().timeIntervalSince(miss) < 300 { continue }
            var dates = [day]
            // Trips after midnight belong to the previous service day (their times run past 24:00),
            // and trip numbers repeat daily, so try the previous day first.
            if TorontoTime.hour(date) < 4 {
                dates.insert(TorontoTime.dateWire(date.addingTimeInterval(-86_400)), at: 0)
            }
            missing.append((trip: trip, key: key, dates: dates))
        }

        if !missing.isEmpty {
            let fetched = await withTaskGroup(of: (String, String, [TripStop]?).self) { group in
                for item in missing {
                    group.addTask {
                        for day in item.dates {
                            if let stops = await Self.fetchTrip(client: client, trip: item.trip, day: day) {
                                return (item.trip, item.key, stops)
                            }
                        }
                        return (item.trip, item.key, nil)
                    }
                }
                var collected: [(String, String, [TripStop]?)] = []
                for await value in group { collected.append(value) }
                return collected
            }
            for (trip, key, stops) in fetched {
                guard let stops else {
                    tripMisses[key] = Date()
                    continue
                }
                tripCache[key] = stops
                result[trip] = stops
            }
        }
        return result
    }

    private static func fetchTrip(client: MetrolinxClient, trip: String, day: String) async -> [TripStop]? {
        let response: TripStatusResponse? = try? await client.fetch("/Schedule/Trip/\(day)/\(trip)")
        guard let stops = response?.trips?.first?.stops.map(inCallingOrder), !stops.isEmpty else { return nil }
        let mapped = stops.compactMap { stop -> TripStop? in
            guard let code = stop.code?.nonEmpty else { return nil }
            return TripStop(code: code, track: stop.track?.actual?.nonEmpty ?? stop.track?.scheduled?.nonEmpty)
        }
        return mapped.isEmpty ? nil : mapped
    }

    // MARK: Disruptions

    private static func cancelledTrips(_ exceptions: ExceptionsResponse?, stationCode: String) -> Set<String> {
        var cancelled = Set<String>()
        for trip in exceptions?.trip ?? [] {
            guard let number = trip.tripNumber?.nonEmpty else { continue }
            if trip.isCancelled?.isTrue == true {
                cancelled.insert(number)
                continue
            }
            let cancelledHere = (trip.stop ?? []).contains {
                $0.code?.trimmed == stationCode && $0.isCancelled?.isTrue == true
            }
            if cancelledHere { cancelled.insert(number) }
        }
        return cancelled
    }

    private static func tripReasons(_ alerts: AlertsResponse?) -> [String: (english: String?, french: String?)] {
        var reasons: [String: (english: String?, french: String?)] = [:]
        for message in alerts?.messages?.message ?? [] {
            let english = message.subjectEnglish?.nonEmpty
            let french = message.subjectFrench?.nonEmpty
            guard english != nil || french != nil else { continue }
            for ref in message.trips ?? [] {
                if let number = ref.tripNumber?.nonEmpty, reasons[number] == nil {
                    reasons[number] = (english: english, french: french)
                }
            }
        }
        return reasons
    }

    private static func stationAlerts(_ alerts: AlertsResponse?, station: Station, network: RailNetwork) -> [StationAlert] {
        var lineCodes = Set<String>()
        for code in station.lineCodes {
            lineCodes.insert(code)
            if let line = network.line(code: code) { lineCodes.insert(line.apiCode) }
        }

        var seen = Set<String>()
        var result: [StationAlert] = []
        for message in alerts?.messages?.message ?? [] {
            let messageLines = Set((message.lines ?? []).compactMap { $0.code?.nonEmpty?.uppercased() })
            let messageStops = Set((message.stops ?? []).compactMap { $0.code?.nonEmpty })
            // Only service disruptions apply to a whole line; amenity alerts (elevators etc.)
            // show only at the stations they name.
            let isServiceDisruption = (message.category ?? "").localizedCaseInsensitiveContains("service disruption")
            let isLineDisruption = isServiceDisruption && !messageLines.isDisjoint(with: lineCodes)
            guard isLineDisruption || messageStops.contains(station.code) else { continue }
            guard let subject = message.subjectEnglish?.nonEmpty else { continue }
            let body = (message.bodyEnglish ?? "").plainText
            guard seen.insert(subject + "|" + body).inserted else { continue }
            result.append(StationAlert(
                id: "\(result.count)-\(message.code ?? subject)",
                subjectEnglish: subject,
                subjectFrench: message.subjectFrench?.nonEmpty ?? "",
                body: body
            ))
        }
        return Array(result.prefix(6))
    }
}
