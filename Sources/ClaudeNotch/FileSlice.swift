import Foundation

/// Reading a bounded slice from the start or end of a (possibly large) file as
/// UTF-8, dropping the partial line at the cut so a line-oriented parser only
/// ever sees whole lines. The transcript and rollout readers each had their own
/// byte-identical copy of this; now they share one. Decoding is lossy, so a
/// non-nil result always means "opened the file" and nil means it couldn't.
enum FileSlice {
    /// At most `bytes` from the END of the file, with a leading partial line
    /// dropped. Nil only when the file can't be opened.
    static func tail(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var s = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s
    }

    /// At most `bytes` from the START of the file, with a trailing partial line
    /// dropped when the read hit the cap (i.e. there is more file after it). Nil
    /// only when the file can't be opened.
    static func head(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        var s = String(decoding: data, as: UTF8.self)
        if data.count == bytes, let nl = s.lastIndex(of: "\n") { s = String(s[..<nl]) }
        return s
    }
}
