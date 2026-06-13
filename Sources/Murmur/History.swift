import Foundation

/// Last-N transcripts as JSONL in Application Support. No rotation needed at this scale.
final class History {
    struct Entry: Codable {
        let ts: String
        let raw: String
        let formatted: String?
    }

    static let defaultFileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur/history.jsonl")

    private let fileURL: URL
    private let settings: Settings

    init(settings: Settings, fileURL: URL = History.defaultFileURL) {
        self.settings = settings
        self.fileURL = fileURL
    }

    func append(raw: String, formatted: String?) {
        guard settings.keepHistory else { return }
        let entry = Entry(
            ts: ISO8601DateFormatter().string(from: Date()),
            raw: raw,
            formatted: formatted
        )
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(Data("\n".utf8))
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }

    func last(_ n: Int) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        let entries = text.split(separator: "\n").compactMap {
            try? decoder.decode(Entry.self, from: Data($0.utf8))
        }
        return Array(entries.suffix(n))
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
