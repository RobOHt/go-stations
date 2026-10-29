import SwiftUI

/// The departure screen, rebuilt for a portrait phone: same title bar, same
/// bilingual column headers, same colours and symbols. The Stops column moves
/// under the destination so nothing ever scrolls sideways.
struct BoardView: View {
    let rows: [BoardRow]
    let station: Station
    let now: Date
    var message: String? = nil
    var isLoading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            BoardTitleBar(now: now)
            DottedRule()
            BoardColumnHeader()

            if rows.isEmpty {
                BoardMessage(text: message ?? "No upcoming trains | Aucun train à venir", isLoading: isLoading)
                DottedRule()
            } else {
                ForEach(rows) { row in
                    BoardRowView(row: row, isUnion: station.isUnion, accessible: station.accessible, now: now)
                    DottedRule()
                }
            }

            if rows.contains(where: \.isExpress) {
                ExpressLegend()
            }
        }
        .padding(.bottom, 6)
        .background(BoardTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Title bar

struct BoardTitleBar: View {
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TrainFrontIcon()
                .fill(BoardTheme.white, style: FillStyle(eoFill: true))
                .frame(width: 22, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text("Train Departures")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(BoardTheme.white)
                Text("Départs des trains")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BoardTheme.frenchGrey)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            Text(TorontoTime.clock(now))
                .font(.system(size: 29, weight: .bold).monospacedDigit())
                .foregroundStyle(BoardTheme.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.identity)
        }
        .padding(.horizontal, BoardTheme.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }
}

// MARK: - Column header

struct BoardColumnHeader: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            BilingualLabel(english: "Scheduled", french: "Programmé")
                .frame(width: BoardTheme.detailIndent + 10, alignment: .leading)
            BilingualLabel(english: "To · Stops", french: "À · Arrêts")
            Spacer(minLength: 6)
            BilingualLabel(english: "Platform", french: "Quai", alignment: .trailing)
        }
        .padding(.horizontal, BoardTheme.horizontalPadding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(BoardTheme.headerStrip)
    }
}

struct BilingualLabel: View {
    let english: String
    let french: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(english)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(BoardTheme.white)
            Text(french)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BoardTheme.frenchGrey)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Row

struct BoardRowView: View {
    let row: BoardRow
    let isUnion: Bool
    let accessible: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 0) {
                Text(TorontoTime.hourMinute(row.scheduled))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(row.isCancelled ? BoardTheme.cancelled : BoardTheme.time)
                    .frame(width: BoardTheme.timeWidth, alignment: .leading)

                ZStack {
                    if row.isExpress {
                        ExpressBolt()
                            .fill(BoardTheme.white)
                            .frame(width: 9, height: 19)
                    }
                }
                .frame(width: BoardTheme.boltWidth)

                LineBadge(code: row.lineCode)
                    .padding(.trailing, 7)

                Text(row.destination)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(BoardTheme.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 6)

                if !row.isCancelled {
                    PlatformCell(row: row, isUnion: isUnion, accessible: accessible, now: now)
                }
            }

            detail
                .padding(.leading, BoardTheme.detailIndent)
        }
        .padding(.horizontal, BoardTheme.horizontalPadding)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detail: some View {
        if row.isCancelled {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Cancelled | Annulé")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(BoardTheme.cancelled)
                if let english = row.reasonEnglish {
                    Text(english)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(BoardTheme.white)
                }
                if let french = row.reasonFrench {
                    Text(french)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(BoardTheme.white)
                }
            }
        } else if row.isDelayed {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delayed | Retardé  ·  \(TorontoTime.hourMinute(row.expected))")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(BoardTheme.delayed)
                stopsText
            }
        } else {
            stopsText
        }
    }

    @ViewBuilder
    private var stopsText: some View {
        if !row.stops.isEmpty {
            Text(row.stops.joined(separator: " - "))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(BoardTheme.white)
                .lineLimit(2)
        }
    }
}

struct PlatformCell: View {
    let row: BoardRow
    let isUnion: Bool
    let accessible: Bool
    let now: Date

    var body: some View {
        if let platform = row.platform {
            HStack(spacing: 5) {
                Text(platform)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(BoardTheme.platform)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if accessible {
                    AccessibleBadge()
                }
            }
        } else if isUnion {
            // Union posts platforms about 10 minutes before departure.
            let minutes = Int(ceil(row.scheduled.addingTimeInterval(-600).timeIntervalSince(now) / 60))
            if minutes > 0 {
                BilingualSmall(english: "Info in \(minutes) min", french: "Infos en \(minutes) min")
            } else {
                BilingualSmall(english: "Wait", french: "Attendez")
            }
        }
    }
}

struct BilingualSmall: View {
    let english: String
    let french: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(english)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(BoardTheme.white)
            Text(french)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(BoardTheme.dimGrey)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct LineBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 11.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: BoardTheme.badgeSize.width, height: BoardTheme.badgeSize.height)
            .background(BoardTheme.badge(code), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Line \(code)")
    }
}

struct AccessibleBadge: View {
    var body: some View {
        Image(systemName: "figure.roll")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(BoardTheme.accessibleBlue, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityLabel("Accessible platform")
    }
}

// MARK: - Footer, messages, rules

struct ExpressLegend: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ExpressBolt()
                .fill(BoardTheme.white)
                .frame(width: 9, height: 19)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("En").foregroundStyle(BoardTheme.white)
                    Text("Express train - will skip some stations").foregroundStyle(BoardTheme.white)
                }
                GridRow {
                    Text("Fr").foregroundStyle(BoardTheme.frenchGrey)
                    Text("Train express - sautera certaines stations").foregroundStyle(BoardTheme.frenchGrey)
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, BoardTheme.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BoardMessage: View {
    let text: String
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView().tint(BoardTheme.white)
            }
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BoardTheme.frenchGrey)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .padding(.horizontal, BoardTheme.horizontalPadding)
    }
}

struct DottedRule: View {
    var body: some View {
        HorizontalLine()
            .stroke(BoardTheme.dots, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.1, 3.6]))
            .frame(height: 1.6)
            .padding(.horizontal, BoardTheme.horizontalPadding)
    }
}

struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// The slanted lightning bolt used for express trips.
struct ExpressBolt: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.58))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY + h * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.90, y: rect.minY + h * 0.40))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY + h * 0.43))
        path.closeSubpath()
        return path
    }
}

/// Front view of a train with rails underneath, as in the board's title bar.
struct TrainFrontIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()

        // Body.
        let body = CGRect(x: rect.minX + w * 0.08, y: rect.minY, width: w * 0.84, height: h * 0.74)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: w * 0.22, height: w * 0.22))

        // Windscreen (cut out with even-odd fill).
        let window = CGRect(x: body.minX + w * 0.14, y: body.minY + h * 0.12,
                            width: body.width - w * 0.28, height: h * 0.26)
        path.addRoundedRect(in: window, cornerSize: CGSize(width: w * 0.06, height: w * 0.06))

        // Headlights.
        let lightSize = w * 0.16
        path.addEllipse(in: CGRect(x: body.minX + w * 0.14, y: body.maxY - h * 0.2, width: lightSize, height: lightSize))
        path.addEllipse(in: CGRect(x: body.maxX - w * 0.14 - lightSize, y: body.maxY - h * 0.2, width: lightSize, height: lightSize))

        // Rails.
        let railTop = rect.minY + h * 0.80
        var rails = Path()
        rails.move(to: CGPoint(x: rect.minX + w * 0.30, y: railTop))
        rails.addLine(to: CGPoint(x: rect.minX + w * 0.08, y: rect.maxY))
        rails.move(to: CGPoint(x: rect.maxX - w * 0.30, y: railTop))
        rails.addLine(to: CGPoint(x: rect.maxX - w * 0.08, y: rect.maxY))
        path.addPath(rails.strokedPath(StrokeStyle(lineWidth: max(1.5, w * 0.09), lineCap: .round)))

        return path
    }
}

// MARK: - Preview (sample data modelled on the Union Station screen)

#Preview("Union board") {
    let now = Date()
    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
    let union = Station(code: "UN", name: "Union Station", latitude: 43.6452, longitude: -79.3806,
                        lineCodes: ["LW", "MI", "KI", "BR", "RH", "ST", "LE"], accessible: true)
    let rows = [
        BoardRow(tripNumber: "1875", lineCode: "LW", lineName: "Lakeshore West", destination: "Lakeshore West",
                 stops: ["Clarkson", "Oakville", "Bronte", "Appleby"], scheduled: at(2), expected: at(2),
                 platform: "13", isExpress: true, isCancelled: false),
        BoardRow(tripNumber: "6325", lineCode: "BR", lineName: "Barrie", destination: "Barrie",
                 stops: ["Downsview Park GO", "Rutherford GO"], scheduled: at(4), expected: at(4),
                 platform: "9, 10", isExpress: false, isCancelled: false),
        BoardRow(tripNumber: "1877", lineCode: "LW", lineName: "Lakeshore West", destination: "Lakeshore West",
                 stops: ["Clarkson", "Oakville", "Bronte", "Appleby"], scheduled: at(14), expected: at(14),
                 platform: nil, isExpress: true, isCancelled: false),
        BoardRow(tripNumber: "3777", lineCode: "KI", lineName: "Kitchener", destination: "Kitchener",
                 stops: [], scheduled: at(15), expected: at(15), platform: nil, isExpress: false,
                 isCancelled: true, reasonEnglish: "Earlier police investigation",
                 reasonFrench: "Enquête policière antérieure"),
        BoardRow(tripNumber: "9026", lineCode: "LE", lineName: "Lakeshore East", destination: "Lakeshore East",
                 stops: ["Danforth", "Scarborough GO", "Eglinton"], scheduled: at(16), expected: at(23),
                 platform: nil, isExpress: false, isCancelled: false),
        BoardRow(tripNumber: "7324", lineCode: "ST", lineName: "Stouffville", destination: "Stouffville",
                 stops: ["Kennedy", "Agincourt", "Milliken"], scheduled: at(23), expected: at(23),
                 platform: nil, isExpress: false, isCancelled: false),
    ]
    return ScrollView {
        BoardView(rows: rows, station: union, now: now)
            .padding(12)
    }
    .background(Color(white: 0.12))
}
