import Foundation

/// Thin client for the Metrolinx Open Data API (https://api.openmetrolinx.com).
/// Every call needs a personal key: register for free at
/// https://api.openmetrolinx.com/OpenDataAPI/Help/Registration/en
struct MetrolinxClient: Sendable {
    let apiKey: String

    static let baseURL = "https://api.openmetrolinx.com/OpenDataAPI/api/V1"
    static let registrationURL = URL(string: "https://api.openmetrolinx.com/OpenDataAPI/Help/Registration/en")!

    func fetch<T: Decodable & MetrolinxEnvelope>(_ path: String) async throws -> T {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MetrolinxError.missingKey }
        guard var components = URLComponents(string: Self.baseURL + path) else { throw MetrolinxError.badResponse }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { throw MetrolinxError.badResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw MetrolinxError.badKey }
            throw MetrolinxError.http(http.statusCode)
        }

        let decoded: T
        do {
            decoded = try Self.decoder.decode(T.self, from: data)
        } catch {
            throw MetrolinxError.badResponse
        }

        // The API reports most failures inside a 200 response via Metadata.ErrorCode.
        let code = decoded.metadata?.errorCode?.trimmingCharacters(in: .whitespaces) ?? "200"
        switch code {
        case "200", "204", "":
            return decoded
        case "401", "403":
            throw MetrolinxError.badKey
        default:
            throw MetrolinxError.api(decoded.metadata?.errorMessage ?? "Error \(code)")
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
}

enum MetrolinxError: LocalizedError {
    case missingKey
    case badKey
    case http(Int)
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Metrolinx API key in Settings."
        case .badKey: return "Metrolinx rejected the API key. Check it in Settings."
        case .http(let status): return "Metrolinx returned HTTP \(status)."
        case .api(let message): return "Metrolinx: \(message)"
        case .badResponse: return "Couldn't read the response from Metrolinx."
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
    }

    struct Track: Decodable, Sendable {
        let scheduled: String?
        let actual: String?
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
