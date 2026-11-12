import WidgetKit
import SwiftUI

struct ProbeEntry: TimelineEntry { let date: Date }

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: .now)], policy: .after(.now.addingTimeInterval(900))))
    }
}

struct ProbeView: View {
    let entry: ProbeEntry
    var body: some View {
        Text("分刻 OK")
            .font(.system(size: 14, weight: .bold))
    }
}

struct ProbeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProbeWidget", provider: ProbeProvider()) { entry in
            ProbeView(entry: entry)
        }
        .configurationDisplayName("分刻探针")
        .description("验证小组件扩展能否被系统加载")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct ProbeBundle: WidgetBundle {
    var body: some Widget { ProbeWidget() }
}
