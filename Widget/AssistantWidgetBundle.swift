import SwiftUI
import WidgetKit

/// AlarmKit presents its alerts through a Live Activity, so an app that schedules alarms must ship
/// a widget extension that declares an `ActivityConfiguration` for `AlarmAttributes`. Without this
/// target the alarm has nothing to draw itself with.
@main
struct PersonalAssistantWidgetBundle: WidgetBundle {
    var body: some Widget {
        AssistantAlarmLiveActivity()
    }
}
