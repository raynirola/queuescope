import Foundation

/// Portable, credential-free queue metadata. Constructed only after the entire file validates.
struct QueueCatalog: Sendable {
    static let maximumBytes = 1_048_576
    static let maximumQueues = 1_000

    struct Entry: Sendable {
        let name: String
        let prefix: String
        let displayName: String?
        let group: String?
    }

    let queues: [Entry]

    private init(queues: [Entry]) {
        self.queues = queues
    }

    static func decode(_ data: Data) throws -> QueueCatalog {
        guard data.count <= maximumBytes else { throw QueueCatalogError.fileTooLarge }
        // Match the Node adapter's UTF-8 format rather than accepting UTF-16 JSON.
        // BOM-less UTF-16/32 ASCII is technically decodable as UTF-8 containing NULs;
        // JSONDecoder would then auto-detect it. Literal NUL is never legal UTF-8 JSON.
        guard !data.contains(0), !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil else {
            throw QueueCatalogError.invalid("The file must contain UTF-8 JSON without a byte-order mark.")
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch let error as QueueCatalogError {
            throw error
        } catch {
            throw QueueCatalogError.invalid("Expected a queue catalog JSON object with schema, version, and queues. Each queue requires name and prefix; optional displayName and group must be strings.")
        }
        guard document.schema == "queuescope.queue-catalog", document.version == 1 else {
            throw QueueCatalogError.invalid("Supported format: queuescope.queue-catalog, version 1.")
        }
        guard document.queues.count <= maximumQueues else { throw QueueCatalogError.tooManyQueues }
        var identities = Set<QueueCatalogIdentity>()
        for (index, entry) in document.queues.enumerated() {
            let path = "Queue \(index + 1)"
            try validate(entry.name, label: "\(path) name", maximumBytes: 512)
            guard !entry.name.contains(":") else {
                throw QueueCatalogError.invalid("\(path) name cannot contain a colon.")
            }
            try validate(entry.prefix, label: "\(path) prefix", maximumBytes: 512)
            if let displayName = entry.displayName {
                try validate(displayName, label: "\(path) displayName", maximumBytes: 256)
            }
            if let group = entry.group {
                try validate(group, label: "\(path) group", maximumBytes: 256)
            }
            guard identities.insert(QueueCatalogIdentity(name: entry.name, prefix: entry.prefix)).inserted else {
                throw QueueCatalogError.invalid("\(path) duplicates a queue name and prefix.")
            }
        }
        return QueueCatalog(queues: document.queues)
    }

    /// Bounds the read itself, even if a file grows after the picker returns.
    static func read(from url: URL) throws -> QueueCatalog {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw QueueCatalogError.invalid("Choose a regular JSON file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try decode(data)
    }

    func validatePrefix(_ prefix: String) throws {
        guard queues.allSatisfy({ $0.prefix.utf8.elementsEqual(prefix.utf8) }) else {
            throw QueueCatalogError.prefixMismatch
        }
    }

    /// Existing metadata always wins, including a label/group the user explicitly cleared.
    func merging(into existing: [QueueSummary]) -> [QueueSummary] {
        var identities = Set(existing.map { QueueCatalogIdentity(name: $0.name, prefix: $0.prefix) })
        var merged = existing
        for entry in queues where identities.insert(QueueCatalogIdentity(name: entry.name, prefix: entry.prefix)).inserted {
            merged.append(QueueSummary(name: entry.name, displayName: entry.displayName, groupName: entry.group,
                                       prefix: entry.prefix, counts: .empty, health: .unknown))
        }
        return merged.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func validate(_ value: String, label: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw QueueCatalogError.invalid("\(label) must contain 1–\(maximumBytes) UTF-8 bytes.")
        }
        guard !value.unicodeScalars.contains(where: { $0.value <= 0x1F || (0x7F...0x9F).contains($0.value) }) else {
            throw QueueCatalogError.invalid("\(label) cannot contain control characters.")
        }
        if let first = value.unicodeScalars.first, let last = value.unicodeScalars.last,
           isWhitespace(first.value) || isWhitespace(last.value) {
            throw QueueCatalogError.invalid("\(label) cannot begin or end with whitespace.")
        }
    }

    // Unicode White_Space plus BOM, matching the adapter without normalizing Redis identifiers.
    private static func isWhitespace(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    private struct Document: Decodable {
        let schema: String
        let version: Int
        let queues: [Entry]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Field.self)
            try container.rejectUnknownFields(allowed: ["schema", "version", "queues"])
            schema = try container.decode(String.self, forKey: Field("schema"))
            version = try container.decode(Int.self, forKey: Field("version"))
            queues = try container.decode([Entry].self, forKey: Field("queues"))
        }
    }

    fileprivate struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
}

extension QueueCatalog.Entry: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QueueCatalog.Field.self)
        try container.rejectUnknownFields(allowed: ["name", "prefix", "displayName", "group"])
        name = try container.decode(String.self, forKey: QueueCatalog.Field("name"))
        prefix = try container.decode(String.self, forKey: QueueCatalog.Field("prefix"))
        // Explicit null is not an optional label in this schema; omit the field instead.
        if container.contains(QueueCatalog.Field("displayName")) {
            displayName = try container.decode(String.self, forKey: QueueCatalog.Field("displayName"))
        } else {
            displayName = nil
        }
        if container.contains(QueueCatalog.Field("group")) {
            group = try container.decode(String.self, forKey: QueueCatalog.Field("group"))
        } else {
            group = nil
        }
    }
}

private extension KeyedDecodingContainer where Key == QueueCatalog.Field {
    func rejectUnknownFields(allowed: Set<String>) throws {
        guard allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw QueueCatalogError.invalid("Unknown fields are not allowed in a queue catalog.")
        }
    }
}

/// Swift strings compare canonically equivalent Unicode as equal. Redis keys do not.
private struct QueueCatalogIdentity: Hashable {
    let name: Data
    let prefix: Data

    init(name: String, prefix: String) {
        self.name = Data(name.utf8)
        self.prefix = Data(prefix.utf8)
    }
}

/// Captured from the live workspace, never from editable connection form fields.
struct QueueCatalogImportTarget: Equatable, Sendable {
    let connectionGeneration: Int
    let scope: String
    let profileID: UUID?
    let connectionName: String
    let endpoint: String
    let prefix: String
}

enum QueueCatalogError: LocalizedError, Equatable {
    case invalid(String)
    case fileTooLarge
    case tooManyQueues
    case prefixMismatch
    case noConnection
    case connectionChanged

    var errorDescription: String? {
        switch self {
        case .invalid(let message): "Invalid queue catalog. \(message)"
        case .fileTooLarge: "Queue catalogs cannot exceed 1 MiB. Nothing was imported."
        case .tooManyQueues: "Queue catalogs cannot contain more than 1,000 queues. Nothing was imported."
        case .prefixMismatch: "Every queue prefix must exactly match the selected connection's prefix. Nothing was imported."
        case .noConnection: "Select and connect to an existing Redis connection before importing a queue catalog."
        case .connectionChanged: "The connection changed while choosing the catalog. Nothing was imported. Choose Import again for the current connection."
        }
    }
}
