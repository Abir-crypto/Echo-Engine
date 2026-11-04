import SwiftUI
import WidgetKit

/// The widget extension: only the recording Live Activity (SPEC § 4.2, § 13.7).
@main
struct RecordingWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}
