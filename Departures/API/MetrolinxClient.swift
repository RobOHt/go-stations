import Foundation

/// Where the app gets live data: the Cloudflare Worker in worker/, which adds the
/// Metrolinx key server-side. `/v1` mirrors Metrolinx's `/OpenDataAPI/api/V1`.
enum ProxyConfig {
    static let baseURL = "https://go-stations.robinzhongsh2.workers.dev/v1"
}

/// Client for Metrolinx Open Data, reached through the GO Stations proxy
/// (worker/ in the repo). The proxy holds the API key, so nothing secret ships
/// in the app; paths are the same as Metrolinx's (`/Stop/NextService/UN`, ...).
struct MetrolinxClient: Sendable {
    func fetch<T: Decodable & MetrolinxEnvelope>(_ path: String) async throws -> T {
        guard let url = URL(string: ProxyConfig.baseURL + path) else { throw MetrolinxError.badResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200

        guard (200..<300).contains(status) else {
            // The proxy answers errors in Metrolinx's own envelope.
            let message = (try? Self.decoder.decode(ErrorEnvelope.self, from: data))?.metadata?.errorMessage
            switch status {
            case 503: throw MetrolinxError.notSetUp
            case 429: throw MetrolinxError.busy
            default: throw MetrolinxError.unavailable(message)
            }
        }

        let decoded: T
        do {
            decoded = try Self.decoder.decode(T.self, from: data)
        } catch {
            throw MetrolinxError.badResponse
        }

        // Metrolinx reports most failures inside a 200 response via Metadata.ErrorCode.
        let code = decoded.metadata?.errorCode?.trimmingCharacters(in: .whitespaces) ?? "200"
        switch code {
        case "200", "204", "":
            return decoded
        case "429":
            throw MetrolinxError.busy
        default:
            throw MetrolinxError.unavailable(decoded.metadata?.errorMessage)
        }
    }

    /// Non-throwing variant, handy with `async let`.
    func result<T: Decodable & MetrolinxEnvelope>(_ path: String) async -> Result<T, Error> {
        do {
            let value: T = try await fetch(path)
            return .success(value)
        } catch {
            return .failure(error)
        }
    }

    /// Metrolinx sends PascalCase keys ("TripNumber"); map them to Swift-style camelCase.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let raw = path.last?.stringValue ?? ""
            return AnyCodingKey(stringValue: raw.prefix(1).lowercased() + raw.dropFirst())
        }
        return decoder
    }()

    private struct ErrorEnvelope: Decodable, MetrolinxEnvelope {
        let metadata: APIMetadata?
    }
}

enum MetrolinxError: LocalizedError {
    case notSetUp
    case busy
    case unavailable(String?)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Live departures aren't switched on yet."
        case .busy: return "Too many requests right now. Trying again shortly."
        case .unavailable(let message):
            if let message, !message.isEmpty { return "Live data unavailable: \(message)" }
            return "Live data is unavailable right now."
        case .badResponse: return "Couldn't read the live data."
        }
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Response shapes (only the fields the app uses)

protocol MetrolinxEnvelope {
    var metadata: APIMetadata? { get }
}

struct APIMetadata: Decodable, Sendable {
    let timeStamp: String?
    let errorCode: String?
    let errorMessage: String?
}

/// Accepts a JSON string, number or bool (Metrolinx sends "0"/"1" for some flags).
struct Lenient: Decodable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? "1" : "0"
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            value = ""
        }
    }

    var isTrue: Bool {
        ["1", "true", "yes", "y"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// GET /Stop/NextService/{StopCode}
struct NextServiceResponse: Decodable, MetrolinxEnvelope, Sendable {
    let metadata: APIMetadata?
    let nextService: Body?

    struct Body: Decodable, Sendable {
        let lines: [Line]?
    }

    struct Line: Decodable, Sendable {
        let stopCode: String?
        let lineCode: String?
        let lineName: String?
        let serviceType: String?
        let directionCode: String?
        let directionName: String?
        let scheduledDepartureTime: String?
        let computedDepartureTime: String?
        let departureStatus: String?
        let scheduledPlatform: String?
        let actualPlatform: String?
        let tripNumber: String?
        let status: String?
    }
}

/// GET /ServiceUpdate/UnionDepartures/All — the Union Station board.
struct UnionDeparturesResponse: Decodable, MetrolinxEnvelope, Sendable {
    let metadata: APIMetadata?
    let allDepartures: Body?

    struct Body: Decodable, Sendable {
        let trip: [Trip]?
    }

    struct Trip: Decodable, Sendable {
        let info: String?
        let tripNumber: String?
        let platform: String?
        let service: String?
        let serviceType: String?
        let time: String?
        let stops: [Stop]?
    }

    struct Stop: Decodable, Sendable {
        let name: String?
        let code: String?
    }
}

/// GET /Schedule/Trip/{yyyyMMdd}/{TripNumber}
struct TripStatusResponse: Decodable, MetrolinxEnvelope, Sendable {
    let metadata: APIMetadata?
    let trips: [Trip]?

    struct Trip: Decodable, Sendable {
        let number: String?
        let destination: String?
        let status: String?
        let stops: [Stop]?
    }

    struct Stop: Decodable, Sendable {
        let code: String?
        let status: String?
        let track: Track?
        let arrivalTime: TimeBlock?
        let departureTime: TimeBlock?
    }

    struct Track: Decodable, Sendable {
        let scheduled: String?
        let actual: String?
    }

    /// Bare "HH:MM" wall-clock times.
    struct TimeBlock: Decodable, Sendable {
        let scheduled: String?
        let computed: String?
    }
}

/// GET /ServiceUpdate/Exceptions/Train — cancelled trips and cancelled stops.
struct ExceptionsResponse: Decodable, MetrolinxEnvelope, Sendable {
    let metadata: APIMetadata?
    let trip: [Trip]?

    struct Trip: Decodable, Sendable {
        let tripNumber: String?
        let isCancelled: Lenient?
        let stop: [Stop]?
    }

    struct Stop: Decodable, Sendable {
        let code: String?
        let isCancelled: Lenient?
    }
}

/// GET /ServiceUpdate/ServiceAlert/All
struct AlertsResponse: Decodable, MetrolinxEnvelope, Sendable {
    let metadata: APIMetadata?
    let messages: Body?

    struct Body: Decodable, Sendable {
        let message: [Message]?
    }

    struct Message: Decodable, Sendable {
        let code: String?
        let subjectEnglish: String?
        let subjectFrench: String?
        let bodyEnglish: String?
        let bodyFrench: String?
        let category: String?
        let subCategory: String?
        let lines: [LineRef]?
        let stops: [StopRef]?
        let trips: [TripRef]?
    }

    struct LineRef: Decodable, Sendable { let code: String? }
    struct StopRef: Decodable, Sendable { let code: String? }
    struct TripRef: Decodable, Sendable { let tripNumber: String? }
}
