import SwiftUI

/// The train a board row was tapped on, and the station whose board it came from.
struct TripSelection: Identifiable {
    let row: BoardRow
    let station: Station

    var id: String { "\(row.id)@\(station.code)" }
}

/// Every stop of one train along a line in its colour. Tapping a stop opens that
/// station's board in another sheet, which can open another train, and so on.
struct TripSheet: View {
    let selection: TripSelection

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var detail: TripDetail?
    @State private var openStation: Station?

    private let network = RailNetwork.shared

    private var row: BoardRow { selection.row }
    private var lineColor: Color { network.line(code: row.lineCode)?.color ?? .gray }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let detail {
                    stopList(detail)
                    sourceNote(detail)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .task {
            detail = await BoardService.shared.tripDetail(for: row, from: selection.station)
        }
        .sheet(item: $openStation) { station in
            StationSheet(station: station)
                .environment(settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Header

    private var terminus: String {
        if let last = detail?.stops.last, let station = network.station(last.code) { return station.name }
        return row.destination
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LineBadge(code: row.lineCode)
                    Text(row.lineName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if row.isExpress {
                        Label("Express", systemImage: "bolt.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("To \(terminus)")
                    .font(.title2.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("Train \(row.tripNumber) · \(TorontoTime.hourMinute(row.scheduled)) from \(selection.station.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if row.isCancelled {
                    Label("Cancelled | Annulé", systemImage: "xmark.circle.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.red)
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

    // MARK: Stops

    private func stopList(_ detail: TripDetail) -> some View {
        VStack(spacing: 0) {
            ForEach(detail.stops) { stop in
                Button {
                    if let station = network.station(stop.code) { openStation = station }
                } label: {
                    StopRow(
                        stop: stop,
                        name: network.station(stop.code)?.name ?? stop.code,
                        role: role(for: stop.code),
                        isOrigin: stop.code == selection.station.code,
                        isFirst: stop.index == 0,
                        isLast: stop.index == detail.stops.count - 1,
                        lineColor: lineColor
                    )
                }
                .buttonStyle(StopRowButtonStyle())
            }
        }
        .padding(.vertical, 6)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func role(for code: String) -> StationRole {
        if code == settings.homeCode { return .home }
        if code == settings.workCode { return .work }
        return .plain
    }

    @ViewBuilder
    private func sourceNote(_ detail: TripDetail) -> some View {
        Group {
            switch detail.source {
            case .live:
                Label("Live times from Metrolinx", systemImage: "dot.radiowaves.left.and.right")
            case .schedule:
                Label("Scheduled times, not live", systemImage: "calendar")
            case nil:
                Label("Times aren't available for this train", systemImage: "questionmark.circle")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

/// One stop: time, a segment of the line with a dot, the station name.
private struct StopRow: View {
    let stop: TripDetail.Stop
    let name: String
    let role: StationRole
    let isOrigin: Bool
    let isFirst: Bool
    let isLast: Bool
    let lineColor: Color

    private var isPast: Bool {
        guard let time = stop.expected ?? stop.time else { return false }
        return time < Date().addingTimeInterval(-30)
    }

    private var isDelayed: Bool {
        guard let time = stop.time, let expected = stop.expected else { return false }
        return expected.timeIntervalSince(time) >= 120
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(stop.time.map(TorontoTime.hourMinute) ?? "")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .strikethrough(isDelayed)
                if isDelayed, let expected = stop.expected {
                    Text(TorontoTime.hourMinute(expected))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            .lineLimit(1)
            .frame(width: 52, alignment: .trailing)

            timeline
                .frame(width: 22)

            HStack(spacing: 8) {
                if role != .plain {
                    Image(systemName: role == .home ? "house.fill" : "briefcase.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 24, height: 24)
                        .background(Color.primary, in: Circle())
                        .accessibilityLabel(role == .home ? "Home" : "Work")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(role != .plain || isOrigin ? .body.weight(.bold) : .body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let platform = stop.platform {
                        Text("Platform \(platform)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(isPast ? .secondary : .primary)
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(role != .plain ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
    }

    private var timeline: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : lineColor)
                    .frame(width: 5)
                Rectangle()
                    .fill(isLast ? Color.clear : lineColor)
                    .frame(width: 5)
            }
            Circle()
                .fill(isOrigin ? lineColor : Color.white)
                .overlay(Circle().strokeBorder(isOrigin ? Color.white : lineColor, lineWidth: isOrigin ? 3 : 3.5))
                .frame(width: isOrigin || isFirst || isLast ? 18 : 14,
                       height: isOrigin || isFirst || isLast ? 18 : 14)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct StopRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear)
    }
}
