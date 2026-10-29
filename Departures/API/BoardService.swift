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
    private var tripCacheDay = ""

    func board(for station: Station, apiKey: String) async throws -> BoardSnapshot {
        let client = MetrolinxClient(apiKey: apiKey)
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
            var dates = [day]
            // Trips after midnight can belong to the previous service day.
            if TorontoTime.hour(date) < 4 {
                dates.append(TorontoTime.dateWire(date.addingTimeInterval(-86_400)))
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
                guard let stops else { continue }
                tripCache[key] = stops
                result[trip] = stops
            }
        }
        return result
    }

    private static func fetchTrip(client: MetrolinxClient, trip: String, day: String) async -> [TripStop]? {
        let response: TripStatusResponse? = try? await client.fetch("/Schedule/Trip/\(day)/\(trip)")
        guard let stops = response?.trips?.first?.stops, !stops.isEmpty else { return nil }
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
            let category = (message.category ?? "") + " " + (message.subCategory ?? "")
            let isLineDisruption = !messageLines.isDisjoint(with: lineCodes)
                && category.localizedCaseInsensitiveContains("disruption")
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
