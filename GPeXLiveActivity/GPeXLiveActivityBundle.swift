import SwiftUI
import WidgetKit

/// GPeX's widget extension exists for one thing: the recording Live Activity.
///
/// There is no Home Screen widget. A widget would have to answer "how is the recording
/// going" from outside the app process, and the only place that knows is the running
/// recording — which is exactly what a Live Activity is for.
@main
struct GPeXLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
    }
}
