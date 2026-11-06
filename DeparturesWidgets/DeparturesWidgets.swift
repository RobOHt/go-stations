import ActivityKit
import SwiftUI
import WidgetKit

/// GO Stations' widget extension. For now it only draws the tracked train's
/// Live Activity; its views live in Departures/Tracking/TripActivity.swift,
/// which the app compiles too.
@main
struct DeparturesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
    }
}

/// A tracked train on the Lock Screen and in the Dynamic Island. The island is
/// black by Apple's rule; the Lock Screen keeps the system's own background.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreen(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .widgetURL(TripActivityAttributes.openURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TripExpandedLeading(attributes: context.attributes)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TripTimeBlock(state: context.state, isStale: context.isStale, fontSize: 24)
                }
                DynamicIslandExpandedRegion(.center) {
                    TripExpandedCenter(attributes: context.attributes, state: context.state,
                                       isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TripRouteProgress(attributes: context.attributes, state: context.state, onDark: true)
                        .padding(.top, 6)
                }
            } compactLeading: {
                TripCompactLeading(attributes: context.attributes, state: context.state, isStale: context.isStale)
            } compactTrailing: {
                TripCompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                TripMinimal(attributes: context.attributes, state: context.state, isStale: context.isStale)
            }
            // The same gap above, below and at the end of the island around the
            // line's pill, so its round end is concentric with the island's.
            .contentMargins([.leading, .top, .bottom], TripActivityLayout.compactInset, for: .compactLeading)
            .keylineTint(context.attributes.lineColorOnDark)
            .widgetURL(TripActivityAttributes.openURL)
        }
    }
}
