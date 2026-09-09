import Foundation

/// Lists the shares a server exports, so the user can pick one instead of
/// typing it. Uses `smbutil view`, which authenticates from the login keychain
/// with `-N` and never prompts.
public enum ShareBrowser {
    public enum BrowseError: Error, CustomStringConvertible {
        /// `smbutil` did not finish in time. Usually a server that accepts TCP
        /// but does not answer SMB, or a wedged client.
        case timedOut
        /// `smbutil` exited non-zero. `message` is its own output.
        case failed(String)

        public var description: String {
            switch self {
            case .timedOut: return "the server did not answer in time"
            case .failed(let m): return m.isEmpty ? "could not list shares" : m
            }
        }
    }

    /// One row of `smbutil view` output.
    public struct Entry: Equatable {
        public let name: String
        public let type: String
        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
        /// Administrative shares such as `IPC$` cannot be mounted as volumes.
        public var isAdministrative: Bool { name.hasSuffix("$") }
        public var isDisk: Bool { type.caseInsensitiveCompare("Disk") == .orderedSame }
    }

    /// Parse the table `smbutil view` prints.
    ///
    /// Columns are space-padded and share names may contain spaces
    /// ("Gamma Time Machine"), so fields are split on runs of two or more
    /// spaces. The comment column can itself contain single spaces, so the
    /// type is the first word of the second field.
    public static func parse(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        var started = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if !started {
                // The dashed rule under the header, or the header itself.
                if line.allSatisfy({ $0 == "-" }) && line.count >= 3 { started = true }
                continue
            }
            if line.isEmpty { continue }
            // "12 shares listed" terminates the table.
            if line.range(of: "^[0-9]+ shares? listed", options: .regularExpression) != nil { break }
            // Split on two-or-more spaces, which preserves names with spaces.
            let columns = line.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let name = columns.first, !name.isEmpty else { continue }
            let type = columns.count > 1 ? (columns[1].split(separator: " ").first.map(String.init) ?? "") : ""
            entries.append(Entry(name: name, type: type))
        }
        return entries
    }

    /// Names of the mountable disk shares on `server`, sorted.
    public static func diskShares(server: String, user: String?, timeout: Double = 15) -> Result<[String], BrowseError> {
        let authority: String
        if let user = user, !user.isEmpty {
            authority = "//\(user)@\(server)"
        } else {
            authority = "//\(server)"
        }
        let r = Subprocess.run("/usr/bin/smbutil", ["view", "-N", authority], timeout: timeout)
        if r.timedOut { return .failure(.timedOut) }
        guard r.status == 0 else {
            let text = (r.stderr + r.stdout)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? ""
            return .failure(.failed(text))
        }
        let names = parse(r.stdout)
            .filter { $0.isDisk && !$0.isAdministrative }
            .map { $0.name }
        return .success(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
