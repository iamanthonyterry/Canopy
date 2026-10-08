import Foundation

/// Splits a folder's contents into gallery sections: folders first, then
/// files grouped by the day they were modified, newest day first.
enum ClipGrouping {
    struct Group: Identifiable {
        let id: String
        let title: String
        let nodes: [FileNode]
    }

    static func groups(for nodes: [FileNode], calendar: Calendar = .current) -> [Group] {
        var result: [Group] = []
        let folders = nodes.filter(\.isDirectory)
        if !folders.isEmpty { result.append(Group(id: "folders", title: "Folders", nodes: folders)) }

        let files = nodes.filter { !$0.isDirectory }
        let byDay = Dictionary(grouping: files) { calendar.startOfDay(for: $0.modified) }
        for day in byDay.keys.sorted(by: >) {
            let title = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
            result.append(Group(id: "day-\(day.timeIntervalSince1970)", title: title, nodes: byDay[day] ?? []))
        }
        return result
    }
}
