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
            // On a trip with changes, the train it has changed to (see `current(_:)`).
            TripLockScreen(attributes: context.attributes.current(context.state), state: context.state,
                           isStale: context.isStale)
                .widgetURL(TripActivityAttributes.openURL)
        } dynamicIsland: { context in
            let attributes = context.attributes.current(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TripExpandedLeading(attributes: attributes)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TripExpandedTrailing(attributes: attributes, state: context.state,
                                         isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    TripExpandedCenter(attributes: attributes, state: context.state,
                                       isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TripExpandedBottom(attributes: attributes, state: context.state,
                                       isStale: context.isStale)
                }
            } compactLeading: {
                TripCompactLeading(attributes: attributes, state: context.state, isStale: context.isStale)
            } compactTrailing: {
                TripCompactTrailing(attributes: attributes, state: context.state, isStale: context.isStale)
            } minimal: {
                TripMinimal(attributes: attributes, state: context.state, isStale: context.isStale)
            }
            // The same gap above, below and at the end of the island around the
            // line's pill, so its round end is concentric with the island's.
            .contentMargins([.leading, .top, .bottom], TripActivityLayout.compactInset, for: .compactLeading)
            .keylineTint(attributes.lineColorOnDark)
            .widgetURL(TripActivityAttributes.openURL)
        }
    }
}
