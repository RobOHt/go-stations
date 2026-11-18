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
    /// GO's feed has stopped updating.
    case stale

    var errorDescription: String? {
        switch self {
        case .notSetUp: return "Live departures aren't switched on yet."
        case .busy: return "Too many requests right now. Trying again shortly."
        case .unavailable(let message):
            if let message, !message.isEmpty { return "Live data unavailable: \(message)" }
            return "Live data is unavailable right now."
        case .badResponse: return "Couldn't read the live data."
        case .stale: return "Live departures haven't updated lately."
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
    @FeedText var timeStamp: String?
    @FeedText var errorCode: String?
    @FeedText var errorMessage: String?
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
    @FeedPart var metadata: APIMetadata?
    let nextService: Body?

    struct Body: Decodable, Sendable {
        @FeedList var lines: [Line]?
    }

    struct Line: Decodable, Sendable {
        @FeedText var stopCode: String?
        @FeedText var lineCode: String?
        @FeedText var lineName: String?
        @FeedText var serviceType: String?
        @FeedText var directionCode: String?
        @FeedText var directionName: String?
        @FeedText var scheduledDepartureTime: String?
        @FeedText var computedDepartureTime: String?
        @FeedText var departureStatus: String?
        @FeedText var scheduledPlatform: String?
        @FeedText var actualPlatform: String?
        @FeedText var tripNumber: String?
        @FeedText var status: String?
    }
}

/// GET /ServiceUpdate/UnionDepartures/All — the Union Station board.
struct UnionDeparturesResponse: Decodable, MetrolinxEnvelope, Sendable {
    @FeedPart var metadata: APIMetadata?
    let allDepartures: Body?

    struct Body: Decodable, Sendable {
        @FeedList var trip: [Trip]?
    }

    struct Trip: Decodable, Sendable {
        @FeedText var info: String?
        @FeedText var tripNumber: String?
        @FeedText var platform: String?
        @FeedText var service: String?
        @FeedText var serviceType: String?
        @FeedText var time: String?
        @FeedList var stops: [Stop]?
    }

    struct Stop: Decodable, Sendable {
        @FeedText var name: String?
        @FeedText var code: String?
    }
}

/// GET /Schedule/Trip/{yyyyMMdd}/{TripNumber}
struct TripStatusResponse: Decodable, MetrolinxEnvelope, Sendable {
    @FeedPart var metadata: APIMetadata?
    @FeedList var trips: [Trip]?

    struct Trip: Decodable, Sendable {
        @FeedText var number: String?
        @FeedText var destination: String?
        @FeedText var status: String?
        @FeedList var stops: [Stop]?
    }

    struct Stop: Decodable, Sendable {
        @FeedText var code: String?
        @FeedText var status: String?
        @FeedPart var track: Track?
        @FeedPart var arrivalTime: TimeBlock?
        @FeedPart var departureTime: TimeBlock?
    }

    struct Track: Decodable, Sendable {
        @FeedText var scheduled: String?
        @FeedText var actual: String?
    }

    /// Bare "HH:MM" wall-clock times.
    struct TimeBlock: Decodable, Sendable {
        @FeedText var scheduled: String?
        @FeedText var computed: String?
    }
}

/// GET /ServiceUpdate/Exceptions/Train — cancelled trips and cancelled stops.
struct ExceptionsResponse: Decodable, MetrolinxEnvelope, Sendable {
    @FeedPart var metadata: APIMetadata?
    @FeedList var trip: [Trip]?

    struct Trip: Decodable, Sendable {
        @FeedText var tripNumber: String?
        let isCancelled: Lenient?
        @FeedList var stop: [Stop]?
    }

    struct Stop: Decodable, Sendable {
        @FeedText var code: String?
        let isCancelled: Lenient?
    }
}

/// GET /ServiceUpdate/ServiceAlert/All
struct AlertsResponse: Decodable, MetrolinxEnvelope, Sendable {
    @FeedPart var metadata: APIMetadata?
    let messages: Body?

    struct Body: Decodable, Sendable {
        @FeedList var message: [Message]?
    }

    struct Message: Decodable, Sendable {
        @FeedText var code: String?
        @FeedText var subjectEnglish: String?
        @FeedText var subjectFrench: String?
        @FeedText var bodyEnglish: String?
        @FeedText var bodyFrench: String?
        @FeedText var category: String?
        @FeedText var subCategory: String?
        @FeedList var lines: [LineRef]?
        @FeedList var stops: [StopRef]?
        @FeedList var trips: [TripRef]?
    }

    struct LineRef: Decodable, Sendable { @FeedText var code: String? }
    struct StopRef: Decodable, Sendable { @FeedText var code: String? }
    struct TripRef: Decodable, Sendable { @FeedText var tripNumber: String? }
}

// MARK: - Reading GO's answers leniently

// GO's feeds are generated, and say the same thing in more than one shape now and
// then: a trip number as a number, one train alone where there's usually a list,
// junk among the trains, "Track": "2" where there's usually an object. Each field
// of the response shapes above is read with one of these, so one odd value costs
// that value (or that item), not the whole answer.

/// Text, also when GO sends it as a number or true/false ("TripNumber": 1925).
@propertyWrapper
struct FeedText: Decodable, Sendable {
    var wrappedValue: String?

    init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let text = try? container.decode(String.self) {
            wrappedValue = text
        } else if let number = try? container.decode(Int.self) {
            wrappedValue = String(number)
        } else if let number = try? container.decode(Double.self) {
            wrappedValue = number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        } else if let flag = try? container.decode(Bool.self) {
            wrappedValue = flag ? "true" : "false"
        } else {
            wrappedValue = nil
        }
    }
}

/// A list, also one item alone where there's usually a list, without the items
/// that aren't what they should be (null, or junk).
@propertyWrapper
struct FeedList<Item: Decodable>: Decodable {
    var wrappedValue: [Item]?

    init(wrappedValue: [Item]?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            wrappedValue = nil
        } else if var list = try? decoder.unkeyedContainer() {
            var items: [Item] = []
            while !list.isAtEnd {
                if let item = try? list.decode(Item.self) {
                    items.append(item)
                } else if (try? list.decode(Skipped.self)) == nil {
                    break
                }
            }
            wrappedValue = items
        } else {
            wrappedValue = (try? Item(from: decoder)).map { [$0] }
        }
    }

    /// Anything at all, to step past an item that isn't what it should be.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension FeedList: Sendable where Item: Sendable {}

/// A part of an answer that's left out when it isn't what it should be, rather
/// than losing the whole answer.
@propertyWrapper
struct FeedPart<Value: Decodable>: Decodable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try? Value(from: decoder)
    }
}

extension FeedPart: Sendable where Value: Sendable {}

/// A field that isn't there at all is nil, as with a plain optional.
extension KeyedDecodingContainer {
    func decode(_ type: FeedText.Type, forKey key: Key) throws -> FeedText {
        try decodeIfPresent(type, forKey: key) ?? FeedText(wrappedValue: nil)
    }

    func decode<Item>(_ type: FeedList<Item>.Type, forKey key: Key) throws -> FeedList<Item> {
        try decodeIfPresent(type, forKey: key) ?? FeedList(wrappedValue: nil)
    }

    func decode<Value>(_ type: FeedPart<Value>.Type, forKey key: Key) throws -> FeedPart<Value> {
        try decodeIfPresent(type, forKey: key) ?? FeedPart(wrappedValue: nil)
    }
}
