import Foundation

/// Pure logic that merges per-process level entries into one `MixerRow` per app identity.
enum MixerGrouping {
    /// A single process's smoothed level plus its resolved identity.
    struct Entry: Equatable {
        let pid: pid_t
        let level: Float
        let isPlaying: Bool
        let identity: AppIdentity
    }

    /// Groups entries by `identity.key`. Combined level is the max across members; the row
    /// is playing if any member is; member pids are sorted. Rows keep first-appearance order.
    static func rows(from entries: [Entry]) -> [MixerRow] {
        var order: [String] = []
        var byKey: [String: MixerRow] = [:]
        for e in entries {
            let key = e.identity.key
            if var row = byKey[key] {
                row.level = max(row.level, e.level)
                row.isPlaying = row.isPlaying || e.isPlaying
                row.pids.append(e.pid)
                byKey[key] = row
            } else {
                order.append(key)
                byKey[key] = MixerRow(id: key,
                                      displayName: e.identity.displayName,
                                      kind: e.identity.kind,
                                      level: e.level,
                                      isPlaying: e.isPlaying,
                                      pids: [e.pid])
            }
        }
        return order.map { key in
            var row = byKey[key]!
            row.pids.sort()
            return row
        }
    }
}
