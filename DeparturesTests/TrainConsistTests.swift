import Foundation
import Testing
@testable import Departures

/// How a train is laid out to scale on the map: its locomotive where GO's GPS has
/// it, at the Union end, and its coaches stretching away from Union behind it.
@Suite("A train to scale")
struct TrainConsistTests {
    typealias Point = TrackGeometry.Point

    /// Union at the origin, Exhibition 2 km west of it, Port Credit 18 km west.
    static let places: [String: Point] = [
        "UN": Point(x: 0, y: 0), "EX": Point(x: -2_000, y: 0), "PO": Point(x: -18_000, y: 0),
    ]

    @Test("heading for Union the locomotive leads; leaving Union it pushes from the back")
    func whichEnd() {
        let station = { (code: String) in Self.places[code] }
        #expect(TrainConsist.locomotiveLeads(codes: ["PO", "EX", "UN"], station: station))
        #expect(!TrainConsist.locomotiveLeads(codes: ["UN", "EX", "PO"], station: station))
        // A run that doesn't reach Union: by which end is nearer it.
        #expect(TrainConsist.locomotiveLeads(codes: ["PO", "EX"], station: station))
        #expect(!TrainConsist.locomotiveLeads(codes: ["EX", "PO"], station: station))
    }

    @Test("the coaches trail behind a locomotive that leads, and run on ahead of one that pushes")
    func layout() {
        let anchor = 1_000.0
        let leading = TrainConsist(coaches: 12, locomotiveLeads: true).vehicles(at: anchor)
        #expect(leading.count == 13)
        #expect(leading[0].kind == .locomotive)
        #expect(abs(leading[0].middle - anchor) < 0.001)
        #expect(leading.last?.kind == .cabCar)
        #expect(leading.dropFirst().allSatisfy { $0.to <= anchor })
        let length = TrainConsist.locomotiveLength + 12 * TrainConsist.coachLength
        #expect(abs((leading.last?.from ?? 0) - (anchor + TrainConsist.locomotiveLength / 2 - length)) < 0.001)

        let pushing = TrainConsist(coaches: 10, locomotiveLeads: false).vehicles(at: anchor)
        #expect(pushing.count == 11)
        #expect(pushing.dropFirst().allSatisfy { $0.from >= anchor })
        #expect(pushing.last?.kind == .cabCar)
        // The cab car drives from the front.
        #expect(pushing.last?.leadsAhead == true)
        #expect(pushing[0].leadsAhead == false)
    }

    @Test("a train GO doesn't give the coaches of is a full-length one")
    func unknownLength() {
        #expect(TrainConsist(coaches: nil, locomotiveLeads: true).coaches == TrainConsist.usualCoaches)
        #expect(TrainConsist(coaches: 0, locomotiveLeads: true).coaches == 1)
    }

    @Test("the worker's coach count comes through with each train, and its absence doesn't cost the train")
    func coachesFromTheWorker() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let with = #"{"trip":"1041","line":"LW","lat":43.6,"lon":-79.4,"time":1764000000,"cars":10}"#
        let without = #"{"trip":"1043","line":"LW","lat":43.6,"lon":-79.4,"time":1764000000}"#
        #expect(try decoder.decode(LiveTrain.self, from: Data(with.utf8)).cars == 10)
        #expect(try decoder.decode(LiveTrain.self, from: Data(without.utf8)).cars == nil)
    }
}
