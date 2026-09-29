import XCTest
@testable import BullMQDashboard

final class RedisURLParserTests: XCTestCase {
    func testRejectsInvalidDatabaseAndPort() {
        for url in ["redis://localhost/not-a-db", "redis://localhost/-1", "redis://localhost/1/2", "redis://localhost:0", "redis://localhost:70000"] {
            XCTAssertThrowsError(try RedisURLParser.parse(url), url)
        }
    }

    func testDecodesCredentialsExactlyOnce() throws {
        let config = try RedisURLParser.parse("redis://literal%252F:secret%252F@localhost")
        XCTAssertEqual(config.username, "literal%2F")
        XCTAssertEqual(config.password, "secret%2F")
    }

    func testParsesPlainRedisURL() throws {
        let config = try RedisURLParser.parse("redis://user:pass@localhost:6380/2", prefix: "bull")
        XCTAssertEqual(config.host, "localhost")
        XCTAssertEqual(config.port, 6380)
        XCTAssertEqual(config.username, "user")
        XCTAssertEqual(config.password, "pass")
        XCTAssertEqual(config.database, 2)
        XCTAssertFalse(config.useTLS)
        XCTAssertEqual(config.prefix, "bull")
    }

    func testParsesTLSRedisURL() throws {
        let config = try RedisURLParser.parse("rediss://cache.example.com")
        XCTAssertEqual(config.host, "cache.example.com")
        XCTAssertEqual(config.port, 6379)
        XCTAssertEqual(config.database, 0)
        XCTAssertTrue(config.useTLS)
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try RedisURLParser.parse("http://localhost:6379")) { error in
            XCTAssertEqual(error as? BullMQDashboardError, .unsupportedURLScheme("http"))
        }
    }

    func testRedactsPassword() {
        XCTAssertEqual(
            RedisURLParser.redacted("redis://user:secret@localhost:6379/0"),
            "redis://user:****@localhost:6379/0"
        )
    }

    func testQueueNameStorePersistsNamesByScope() {
        let suiteName = "QueueNameStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QueueNameStore(defaults: defaults)

        store.save(["email", "reports", "email"], scope: "local:6379/0:bull")
        store.save(["video"], scope: "prod:6379/0:bull")

        XCTAssertEqual(store.load(scope: "local:6379/0:bull"), ["email", "reports"])
        XCTAssertEqual(store.load(scope: "prod:6379/0:bull"), ["video"])
        XCTAssertEqual(store.load(scope: "missing"), [])
    }

    func testConnectionProfileStorePersistsLastActiveProfileID() {
        let suiteName = "ConnectionProfileStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ConnectionProfileStore(defaults: defaults)
        let profileID = UUID()

        XCTAssertNil(store.loadLastActiveProfileID())

        store.saveLastActiveProfileID(profileID)
        XCTAssertEqual(store.loadLastActiveProfileID(), profileID)

        store.clearLastActiveProfileID()
        XCTAssertNil(store.loadLastActiveProfileID())
    }

    func testQueueMetadataStorePersistsQueueOverviewsByScope() {
        let suiteName = "QueueMetadataStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QueueMetadataStore(defaults: defaults)
        var counts = QueueCounts.empty
        counts.waiting = 8
        counts.failed = 2

        store.save(
            [
                QueueSummary(
                    name: "email",
                    groupName: "Production",
                    prefix: "bull",
                    counts: counts,
                    health: .warning
                )
            ],
            scope: "local:6379/0:bull"
        )

        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.name, "email")
        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.groupName, "Production")
        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.counts.waiting, 8)
        XCTAssertEqual(store.load(scope: "local:6379/0:bull").first?.health, .warning)
        XCTAssertEqual(store.load(scope: "missing"), [])
    }

    func testQueueWorkspacePreferenceStorePersistsSelectionByScope() {
        let suiteName = "QueueWorkspacePreferenceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = QueueWorkspacePreferenceStore(defaults: defaults)

        store.save(
            QueueWorkspacePreference(selectedQueueName: "email", selectedView: "runs"),
            scope: "local:6379/0:bull"
        )
        store.save(
            QueueWorkspacePreference(selectedQueueName: "reports", selectedView: "metrics"),
            scope: "prod:6379/0:bull"
        )

        XCTAssertEqual(store.load(scope: "local:6379/0:bull")?.selectedQueueName, "email")
        XCTAssertEqual(store.load(scope: "local:6379/0:bull")?.selectedView, "runs")
        XCTAssertEqual(store.load(scope: "prod:6379/0:bull")?.selectedQueueName, "reports")
        XCTAssertNil(store.load(scope: "missing"))
    }
}

final class MemoryConnectionCredentials: ConnectionCredentialStore {
    var values: [UUID: String] = [:]
    var failWrites = false
    func read(id: UUID) throws -> String? { values[id] }
    func write(_ url: String, id: UUID) throws {
        if failWrites { throw BullMQDashboardError.redis("Keychain unavailable") }
        values[id] = url
    }
    func delete(id: UUID) throws { values[id] = nil }
}

final class PersistenceTests: XCTestCase {
    private func withStorage(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "QueueScopePersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(defaults, directory.appendingPathComponent("metrics.json"))
    }

    func testProfileSecretsAreOnlyStoredInCredentialStore() throws {
        try withStorage { defaults, _ in
            let credentials = MemoryConnectionCredentials()
            let store = ConnectionProfileStore(defaults: defaults, credentials: credentials)
            let profile = RedisConnectionProfile(name: "Test", redisURL: "redis://private-user:secret%252F@localhost/2", isReadOnly: true)
            try store.save([profile])
            let persisted = String(data: defaults.data(forKey: "redis.connection.profiles")!, encoding: .utf8)!
            XCTAssertFalse(persisted.contains("secret"))
            XCTAssertFalse(persisted.contains("private-user"))
            XCTAssertEqual(try store.load(), [profile])
            try store.delete(profile)
            XCTAssertNil(credentials.values[profile.id])
            XCTAssertTrue(try store.load().isEmpty)
        }
    }

    func testLegacyProfileMigrationPreservesDataOnKeychainFailure() throws {
        try withStorage { defaults, _ in
            let id = UUID()
            let legacy = try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "name": "Test", "redisURL": "redis://user:secret@localhost", "prefix": "bull"]])
            defaults.set(legacy, forKey: "redis.connection.profiles")
            let credentials = MemoryConnectionCredentials()
            credentials.failWrites = true
            let store = ConnectionProfileStore(defaults: defaults, credentials: credentials)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(defaults.data(forKey: "redis.connection.profiles"), legacy)
            credentials.failWrites = false
            XCTAssertEqual(try store.load().first?.redisURL, "redis://user:secret@localhost")
            XCTAssertFalse(String(data: defaults.data(forKey: "redis.connection.profiles")!, encoding: .utf8)!.contains("secret"))
        }
    }

    func testMixedMigrationDoesNotOverwriteAlreadySecuredProfile() throws {
        try withStorage { defaults, _ in
            let credentials = MemoryConnectionCredentials()
            let store = ConnectionProfileStore(defaults: defaults, credentials: credentials)
            let secured = RedisConnectionProfile(name: "Secured", redisURL: "redis://secured:password@localhost")
            try store.save([secured])
            var raw = try JSONSerialization.jsonObject(with: defaults.data(forKey: "redis.connection.profiles")!) as! [[String: Any]]
            raw.append(["id": UUID().uuidString, "name": "Legacy", "redisURL": "redis://legacy:secret@localhost", "prefix": "bull"])
            defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "redis.connection.profiles")
            XCTAssertEqual(try store.load().first?.redisURL, secured.redisURL)
            XCTAssertEqual(credentials.values[secured.id], secured.redisURL)
        }
    }

    func testMissingKeychainEntryDoesNotSilentlyDropCredentials() throws {
        try withStorage { defaults, _ in
            let credentials = MemoryConnectionCredentials()
            let store = ConnectionProfileStore(defaults: defaults, credentials: credentials)
            try store.save([RedisConnectionProfile(name: "Test", redisURL: "redis://user:password@localhost")])
            credentials.values = [:]
            let missing = try XCTUnwrap(store.load().first)
            XCTAssertTrue(missing.credentialsInKeychain)
            let new = RedisConnectionProfile(name: "New", redisURL: "redis://new:password@localhost")
            try store.save([missing, new])
            XCTAssertNil(credentials.values[missing.id])
            XCTAssertEqual(try store.load().count, 2)
            try store.delete(missing)
            XCTAssertEqual(try store.load(), [new])
        }
    }

    func testMetricRetentionSeparatesConnectionsAndQueues() throws {
        try withStorage { defaults, file in
            let store = MetricSnapshotStore(fileURL: file, legacyDefaults: defaults)
            for index in 0..<121 {
                try store.append(QueueMetricSnapshot(connectionScope: "local/0:bull", queueName: "email", capturedAt: Date(timeIntervalSince1970: Double(index)), counts: QueueCountsSnapshot(counts: .empty)))
            }
            try store.append(QueueMetricSnapshot(connectionScope: "prod/0:bull", queueName: "email", capturedAt: Date(), counts: QueueCountsSnapshot(counts: .empty)))
            XCTAssertEqual(try store.load(scope: "local/0:bull").count, 120)
            XCTAssertEqual(try store.load(scope: "prod/0:bull").count, 1)
            XCTAssertTrue(try store.load(scope: "prod/1:bull").isEmpty)
            XCTAssertNil(defaults.data(forKey: "queue.metric.snapshots"))
            XCTAssertEqual(try MetricSnapshotStore(fileURL: file, legacyDefaults: defaults).load(scope: "prod/0:bull").count, 1)
        }
    }

    func testNativeMetricHistoryIsBoundedAndNotDuplicated() throws {
        try withStorage { defaults, file in
            let store = MetricSnapshotStore(fileURL: file, legacyDefaults: defaults)
            let series = BullMQMetricSeries(count: 5000, previousTimestamp: nil, previousCount: 0, data: Array(repeating: 1, count: 5000))
            for index in 0..<3 {
                try store.append(QueueMetricSnapshot(connectionScope: "local", queueName: "email", capturedAt: Date(timeIntervalSince1970: Double(index)), counts: QueueCountsSnapshot(counts: .empty), nativeMetrics: BullMQNativeMetrics(completed: series, failed: series)))
            }
            let snapshots = try store.load(scope: "local")
            XCTAssertEqual(snapshots.count, 3)
            XCTAssertEqual(snapshots.compactMap(\.nativeMetrics).count, 1)
            XCTAssertEqual(snapshots.first?.nativeMetrics?.completed.data.count, 1440)
            XCTAssertLessThan(try Data(contentsOf: file).count, 20000)
        }
    }

    func testLegacyMetricsAreArchivedWithoutAttributingAnEnvironment() throws {
        try withStorage { defaults, file in
            let legacy = Data("legacy metric data".utf8)
            defaults.set(legacy, forKey: "queue.metric.snapshots")
            let store = MetricSnapshotStore(fileURL: file, legacyDefaults: defaults)
            XCTAssertTrue(try store.load(scope: "prod").isEmpty)
            XCTAssertNil(defaults.data(forKey: "queue.metric.snapshots"))
            let archives = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            XCTAssertEqual(archives.count, 1)
            XCTAssertEqual(try Data(contentsOf: archives[0]), legacy)
        }
    }
}
