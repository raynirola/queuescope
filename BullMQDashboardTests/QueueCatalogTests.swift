import XCTest
@testable import BullMQDashboard

final class QueueCatalogTests: XCTestCase {
    func testSharedValidFixtureAndRejectionFixtures() throws {
        let valid = try QueueCatalog.decode(catalogFixture("valid-v1.json"))
        XCTAssertEqual(valid.queues.count, 4)
        XCTAssertNoThrow(try valid.validatePrefix("team:prod"))
        XCTAssertEqual(valid.merging(into: []).count, 4)
        XCTAssertTrue(try QueueCatalog.decode(catalogFixture("empty-v1.json")).queues.isEmpty)
        for filename in ["malformed.json", "duplicate-v1.json", "unknown-fields-v1.json", "unsupported-version.json", "invalid-name-v1.json", "invalid-whitespace-v1.json", "invalid-control-v1.json"] {
            XCTAssertThrowsError(try QueueCatalog.decode(catalogFixture(filename)), filename)
        }
        let mixed = try QueueCatalog.decode(catalogFixture("mixed-prefix-v1.json"))
        let prefix = try XCTUnwrap(mixed.queues.first?.prefix)
        XCTAssertThrowsError(try mixed.validatePrefix(prefix))
    }

    func testStrictShapeTypesAndUnknownFields() throws {
        let invalid = [
            "[]", "null", "{}",
            #"{"schema":"queuescope.queue-catalog","version":true,"queues":[]}"#,
            #"{"schema":"queuescope.queue-catalog","version":"1","queues":[]}"#,
            #"{"schema":"queuescope.queue-catalog","version":1.5,"queues":[]}"#,
            #"{"schema":"queuescope.queue-catalog","version":1,"queues":[],"connection":{}}"#,
            #"{"schema":"queuescope.queue-catalog","version":1,"queues":{}}"#,
            #"{"schema":"other","version":1,"queues":[]}"#
        ]
        for json in invalid { XCTAssertThrowsError(try QueueCatalog.decode(Data(json.utf8)), json) }
        let entries: [[String: Any]] = [
            ["name": "email"], ["prefix": "bull"],
            ["name": 1, "prefix": "bull"], ["name": "email", "prefix": NSNull()],
            ["name": "email", "prefix": "bull", "displayName": NSNull()],
            ["name": "email", "prefix": "bull", "group": false],
            ["name": "email", "prefix": "bull", "password": "must-not-be-accepted"],
            ["name": "email", "prefix": "bull", "readOnly": false],
            ["name": "email", "prefix": "bull", "groupName": "wrong-field"]
        ]
        for entry in entries { XCTAssertThrowsError(try QueueCatalog.decode(catalogData([entry]))) }
        XCTAssertThrowsError(try QueueCatalog.decode(Data([0xFF, 0xFE, 0xFD])))
        XCTAssertThrowsError(try QueueCatalog.decode(Data(#"{"schema":"queuescope.queue-catalog","version":1,"queues":[{"name":"\uD800","prefix":"bull"}]}"#.utf8)))
    }

    func testIdentifiersLabelsControlsAndSurroundingWhitespace() throws {
        for field in ["name", "prefix", "displayName", "group"] {
            for invalid in ["", " value", "value ", "\u{00A0}value", "value\u{FEFF}", "\u{3000}value", "va\n lue", "a\u{0000}b", "a\u{007F}b", "a\u{009F}b"] {
                var entry: [String: Any] = ["name": "email", "prefix": "bull"]
                entry[field] = invalid
                XCTAssertThrowsError(try QueueCatalog.decode(catalogData([entry])), "\(field): \(invalid.debugDescription)")
            }
        }
        XCTAssertThrowsError(try QueueCatalog.decode(catalogData([["name": "email:send", "prefix": "bull"]])))
        let catalog = try QueueCatalog.decode(catalogData([
            ["name": "通知📬", "prefix": "team:東京", "displayName": "Email notifications", "group": "業務 キュー"],
            ["name": "a b", "prefix": "team:東京"]
        ]))
        XCTAssertEqual(catalog.queues.count, 2)
        XCTAssertNoThrow(try catalog.validatePrefix("team:東京"))
    }

    func testRejectsBOMLessUTF16AndUTF32InsteadOfAutodetectingThem() throws {
        let json = #"{"schema":"queuescope.queue-catalog","version":1,"queues":[]}"#
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let bytes = try XCTUnwrap(json.data(using: encoding))
            XCTAssertThrowsError(try QueueCatalog.decode(bytes))
        }
        var markedUTF8 = Data([0xEF, 0xBB, 0xBF])
        markedUTF8.append(Data(json.utf8))
        XCTAssertThrowsError(try QueueCatalog.decode(markedUTF8))
        XCTAssertNoThrow(try QueueCatalog.decode(Data(json.utf8)))
    }

    func testLimitsCountUTF8BytesRatherThanCharacters() throws {
        for field in ["name", "prefix", "displayName", "group"] {
            let limit = (field == "name" || field == "prefix") ? 512 : 256
            var entry: [String: Any] = ["name": "email", "prefix": "bull"]
            entry[field] = String(repeating: "é", count: limit / 2)
            XCTAssertNoThrow(try QueueCatalog.decode(catalogData([entry])))
            entry[field] = String(repeating: "é", count: limit / 2) + "a"
            XCTAssertThrowsError(try QueueCatalog.decode(catalogData([entry])))
        }
        let thousand = (0..<1_000).map { ["name": "queue-\($0)", "prefix": "bull"] }
        XCTAssertEqual(try QueueCatalog.decode(catalogData(thousand)).queues.count, 1_000)
        XCTAssertThrowsError(try QueueCatalog.decode(catalogData(thousand + [["name": "overflow", "prefix": "bull"]])))
        var bytes = try catalogData([])
        bytes.append(Data(repeating: 0x20, count: QueueCatalog.maximumBytes - bytes.count))
        XCTAssertNoThrow(try QueueCatalog.decode(bytes))
        bytes.append(0x20)
        XCTAssertThrowsError(try QueueCatalog.decode(bytes)) { XCTAssertEqual($0 as? QueueCatalogError, .fileTooLarge) }
    }

    func testBoundedFileReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try catalogData([["name": "email", "prefix": "bull"]]).write(to: url)
        XCTAssertEqual(try QueueCatalog.read(from: url).queues.count, 1)
        try Data(repeating: 0x20, count: QueueCatalog.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try QueueCatalog.read(from: url)) { XCTAssertEqual($0 as? QueueCatalogError, .fileTooLarge) }
    }

    func testFileReaderRejectsNonregularResources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-directory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try QueueCatalog.read(from: directory))
    }

    func testDuplicatesAreExactNameAndPrefixPairsWithoutUnicodeNormalization() throws {
        XCTAssertThrowsError(try QueueCatalog.decode(catalogData([
            ["name": "email", "prefix": "bull"], ["name": "email", "prefix": "bull"]
        ])))
        let mixed = try QueueCatalog.decode(catalogData([
            ["name": "email", "prefix": "bull"], ["name": "email", "prefix": "other"]
        ]))
        XCTAssertEqual(mixed.queues.count, 2)
        XCTAssertThrowsError(try mixed.validatePrefix("bull"))
        let unicode = try QueueCatalog.decode(catalogData([
            ["name": "café", "prefix": "bull"], ["name": "cafe\u{301}", "prefix": "bull"]
        ]))
        XCTAssertEqual(unicode.merging(into: []).count, 2)
        let prefix = try QueueCatalog.decode(catalogData([["name": "email", "prefix": "café"]]))
        XCTAssertThrowsError(try prefix.validatePrefix("cafe\u{301}"))
    }

    func testMergePreservesExistingLabelsGroupsAndLiveCountsIncludingClearedValues() throws {
        let catalog = try QueueCatalog.decode(catalogData([
            ["name": "email", "prefix": "bull", "displayName": "Exporter", "group": "Exporter group"],
            ["name": "reports", "prefix": "bull", "displayName": "Reports", "group": "Analytics"]
        ]))
        var counts = QueueCounts.empty
        counts.active = 7
        var existing = QueueSummary(name: "email", displayName: "My label", groupName: "My group", prefix: "bull", counts: counts, health: .busy)
        existing.isPaused = true
        let merged = catalog.merging(into: [existing])
        XCTAssertEqual(merged.first, existing)
        XCTAssertEqual(merged.last?.displayName, "Reports")
        XCTAssertEqual(merged.last?.groupName, "Analytics")
        XCTAssertEqual(catalog.merging(into: merged), merged)
        existing.displayName = nil
        existing.groupName = nil
        XCTAssertEqual(catalog.merging(into: [existing]).first, existing)
    }
}

@MainActor
final class QueueCatalogImportTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "QueueCatalogImportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeModel(defaults: UserDefaults, engine: CatalogTestEngine = CatalogTestEngine(), credentials: MemoryConnectionCredentials = MemoryConnectionCredentials()) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AppModel(
            engine: engine,
            profileStore: ConnectionProfileStore(defaults: defaults, credentials: credentials),
            snapshotStore: MetricSnapshotStore(fileURL: directory.appendingPathComponent("metrics.json"), legacyDefaults: defaults),
            queueNameStore: QueueNameStore(defaults: defaults),
            queueMetadataStore: QueueMetadataStore(defaults: defaults),
            workspacePreferenceStore: QueueWorkspacePreferenceStore(defaults: defaults)
        )
    }

    func testCapturesLiveConnectionRatherThanEditedFormAndDoesNotChangePermissionsOrCallRedis() async throws {
        let defaults = makeDefaults()
        let engine = CatalogTestEngine()
        let credentials = MemoryConnectionCredentials()
        let model = makeModel(defaults: defaults, engine: engine, credentials: credentials)
        let profile = RedisConnectionProfile(name: "Production", redisURL: "rediss://user:secret@production/2", prefix: "prod:jobs", isReadOnly: true)
        model.profiles = [profile]
        await model.connect(profile: profile)
        let target = try model.captureQueueCatalogImportTarget()
        let config = model.activeConnection
        let credentialValues = credentials.values
        let requests = engine.requests
        let profileMetadata = defaults.data(forKey: "redis.connection.profiles")
        model.redisURL = "redis://different-server/9"
        model.prefix = "different"
        model.connectionReadOnly = false
        model.connectionProfileName = "Form draft"

        XCTAssertEqual(try model.importQueueCatalog(data: catalogData([["name": "email", "prefix": "prod:jobs"]]), target: target), 1)

        XCTAssertEqual(target.profileID, profile.id)
        XCTAssertEqual(target.endpoint, "production:6379/2")
        XCTAssertEqual(target.connectionName, "Production")
        XCTAssertEqual(model.activeConnection, config)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertFalse(model.canWrite)
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertEqual(credentials.values, credentialValues)
        XCTAssertEqual(defaults.data(forKey: "redis.connection.profiles"), profileMetadata)
        XCTAssertEqual(engine.requests, requests)
        XCTAssertNil(model.selectedQueue)
        XCTAssertEqual(model.queues.first?.prefix, "prod:jobs")
    }

    func testRejectsEntireInvalidOrMixedPrefixFileWithoutPartialMutation() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        await model.connect()
        let target = try model.captureQueueCatalogImportTarget()
        let existing = QueueSummary(name: "existing", displayName: "Keep me", groupName: "Local", prefix: "bull", counts: .empty, health: .unknown)
        model.queues = [existing]
        QueueMetadataStore(defaults: defaults).save(model.queues, scope: target.scope)
        let persisted = defaults.data(forKey: "redis.connection.queue.metadata")
        let payloads = [
            try catalogData([["name": "valid-first", "prefix": "bull"], ["name": "bad:last", "prefix": "bull"]]),
            try catalogData([["name": "valid-first", "prefix": "bull"], ["name": "last", "prefix": "other"]]),
            try catalogFixture("duplicate-v1.json"), try catalogFixture("malformed.json"),
            try catalogFixture("unknown-fields-v1.json"), try catalogFixture("unsupported-version.json"),
            Data(repeating: 0x20, count: QueueCatalog.maximumBytes + 1)
        ]
        for payload in payloads {
            XCTAssertThrowsError(try model.importQueueCatalog(data: payload, target: target))
            XCTAssertEqual(model.queues, [existing])
            XCTAssertEqual(defaults.data(forKey: "redis.connection.queue.metadata"), persisted)
        }
    }

    func testReimportIsIdempotentPreservesUserEditsAndPersistsAcrossRelaunch() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        await model.connect()
        let target = try model.captureQueueCatalogImportTarget()
        let data = try catalogData([["name": "email", "prefix": "bull", "displayName": "Catalog label", "group": "Catalog group"]])
        XCTAssertEqual(try model.importQueueCatalog(data: data, target: target), 1)
        await model.addManualQueue(named: "email", displayName: "User label")
        model.assignQueue(named: "email", toGroup: "User group")
        let edited = model.queues
        let persisted = defaults.data(forKey: "redis.connection.queue.metadata")
        XCTAssertEqual(try model.importQueueCatalog(data: data, target: target), 0)
        XCTAssertEqual(model.queues, edited)
        XCTAssertEqual(defaults.data(forKey: "redis.connection.queue.metadata"), persisted)
        model.assignQueue(named: "email", toGroup: nil)
        XCTAssertEqual(try model.importQueueCatalog(data: data, target: target), 0)
        XCTAssertNil(model.queues.first?.groupName)
        await model.disconnect()

        let relaunched = makeModel(defaults: defaults)
        await relaunched.connect()
        XCTAssertEqual(relaunched.queues.map(\.name), ["email"])
        XCTAssertEqual(relaunched.queues.first?.displayName, "User label")
        XCTAssertNil(relaunched.queues.first?.groupName)
        let newTarget = try relaunched.captureQueueCatalogImportTarget()
        XCTAssertEqual(try relaunched.importQueueCatalog(data: data, target: newTarget), 0)
        await relaunched.disconnect()
    }

    func testImportDoesNotAlterOtherConnectionWithSamePrefix() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let store = QueueMetadataStore(defaults: defaults)
        await model.connect()
        let firstTarget = try model.captureQueueCatalogImportTarget()
        try model.importQueueCatalog(data: catalogData([["name": "first", "prefix": "bull"]]), target: firstTarget)
        let firstQueues = store.load(scope: firstTarget.scope)
        await model.disconnect()
        model.redisURL = "redis://other-server:6380/2"
        await model.connect()
        let secondTarget = try model.captureQueueCatalogImportTarget()
        try model.importQueueCatalog(data: catalogData([["name": "second", "prefix": "bull"]]), target: secondTarget)
        XCTAssertEqual(store.load(scope: firstTarget.scope), firstQueues)
        XCTAssertEqual(store.load(scope: secondTarget.scope).map(\.name), ["second"])
    }

    func testUnicodeQueueIdentitiesRemainDistinctAcrossSelectionGroupingRemovalAndRelaunch() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.prefix = "team:prod"
        await model.connect()
        let target = try model.captureQueueCatalogImportTarget()
        let data = try catalogFixture("valid-v1.json")
        XCTAssertEqual(try model.importQueueCatalog(data: data, target: target), 4)
        XCTAssertEqual(Set(model.queues.map(\.id)).count, 4)
        let composed = "café"
        let decomposed = "cafe\u{301}"
        model.assignQueues(named: [decomposed], toGroup: "Only decomposed")
        XCTAssertNil(model.queues.first { $0.name.utf8.elementsEqual(composed.utf8) }?.groupName)
        let queue = try XCTUnwrap(model.queues.first { $0.name.utf8.elementsEqual(decomposed.utf8) })
        XCTAssertEqual(queue.groupName, "Only decomposed")
        model.selectQueue(queue)
        await model.refreshSelectedQueue()
        XCTAssertTrue(try XCTUnwrap(model.selectedQueue).name.utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(model.queues.count, 4)
        XCTAssertEqual(try model.importQueueCatalog(data: data, target: target), 0)
        await model.disconnect()

        let relaunched = makeModel(defaults: defaults)
        relaunched.prefix = "team:prod"
        await relaunched.connect()
        XCTAssertEqual(Set(relaunched.queues.map(\.id)).count, 4)
        XCTAssertTrue(try XCTUnwrap(relaunched.selectedQueue).name.utf8.elementsEqual(decomposed.utf8))
        relaunched.removeQueue(named: composed)
        XCTAssertEqual(relaunched.queues.count, 3)
        XCTAssertTrue(relaunched.queues.contains { $0.name.utf8.elementsEqual(decomposed.utf8) })
        XCTAssertEqual(relaunched.selectedQueue?.groupName, "Only decomposed")
        XCTAssertEqual(QueueNameStore(defaults: defaults).load(scope: target.scope).count, 3)
        await relaunched.disconnect()
    }

    func testConnectionSwitchAndReconnectRejectCapturedTarget() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        await model.connect()
        let target = try model.captureQueueCatalogImportTarget()
        let catalog = try QueueCatalog.decode(catalogData([["name": "email", "prefix": "bull"]]))
        await model.disconnect()
        XCTAssertThrowsError(try model.importQueueCatalog(catalog, target: target)) { XCTAssertEqual($0 as? QueueCatalogError, .connectionChanged) }
        model.redisURL = "redis://other-server"
        await model.connect()
        XCTAssertThrowsError(try model.importQueueCatalog(catalog, target: target)) { XCTAssertEqual($0 as? QueueCatalogError, .connectionChanged) }
        await model.disconnect()
        model.redisURL = "redis://127.0.0.1:6379"
        await model.connect()
        XCTAssertThrowsError(try model.importQueueCatalog(catalog, target: target)) { XCTAssertEqual($0 as? QueueCatalogError, .connectionChanged) }
        XCTAssertTrue(model.queues.isEmpty)
    }

    func testCanonicallyEquivalentPrefixesKeepSeparatePersistedWorkspaces() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let composed = "café"
        let decomposed = "cafe\u{301}"
        model.prefix = composed
        await model.connect()
        let firstTarget = try model.captureQueueCatalogImportTarget()
        try model.importQueueCatalog(data: catalogData([["name": "first", "prefix": composed, "displayName": "First label"]]), target: firstTarget)
        model.assignQueue(named: "first", toGroup: "First group")
        model.setRefreshInterval(30)
        await model.disconnect()
        model.prefix = decomposed
        await model.connect()
        XCTAssertTrue(model.queues.isEmpty)
        XCTAssertEqual(model.refreshInterval, 15)
        let secondTarget = try model.captureQueueCatalogImportTarget()
        XCTAssertThrowsError(try model.importQueueCatalog(data: catalogData([["name": "wrong-prefix", "prefix": composed]]), target: secondTarget))
        try model.importQueueCatalog(data: catalogData([["name": "second", "prefix": decomposed, "displayName": "Second label"]]), target: secondTarget)
        model.assignQueue(named: "second", toGroup: "Second group")
        model.setRefreshInterval(60)
        await model.disconnect()

        let relaunched = makeModel(defaults: defaults)
        for (prefix, name, label, group, interval) in [(composed, "first", "First label", "First group", 30), (decomposed, "second", "Second label", "Second group", 60)] {
            relaunched.prefix = prefix
            await relaunched.connect()
            XCTAssertEqual(relaunched.queues.map(\.name), [name])
            XCTAssertEqual(relaunched.queues.first?.displayName, label)
            XCTAssertEqual(relaunched.queues.first?.groupName, group)
            XCTAssertEqual(relaunched.refreshInterval, interval)
            XCTAssertTrue(try XCTUnwrap(relaunched.queues.first).prefix.utf8.elementsEqual(prefix.utf8))
            await relaunched.disconnect()
        }
    }

    func testImportRequiresExistingLiveWorkspaceAndRejectsDemo() async throws {
        let model = makeModel(defaults: makeDefaults())
        XCTAssertFalse(model.canImportQueueCatalog)
        XCTAssertThrowsError(try model.captureQueueCatalogImportTarget())
        await model.startDemo()
        XCTAssertFalse(model.canImportQueueCatalog)
        XCTAssertThrowsError(try model.captureQueueCatalogImportTarget())
    }

    func testPersistenceFailureDoesNotPublishPartialImport() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        await model.connect()
        let target = try model.captureQueueCatalogImportTarget()
        let corrupt = Data("corrupt-metadata".utf8)
        defaults.set(corrupt, forKey: "redis.connection.queue.metadata")
        XCTAssertThrowsError(try model.importQueueCatalog(data: catalogData([["name": "email", "prefix": "bull"]]), target: target))
        XCTAssertTrue(model.queues.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "redis.connection.queue.metadata"), corrupt)
    }
}

final class QueueCatalogScopePersistenceTests: XCTestCase {
    private let composedScope = "localhost:6379/0:café"
    private let decomposedScope = "localhost:6379/0:cafe\u{301}"

    private func withStorage(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "QueueCatalogScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(defaults, directory.appendingPathComponent("metrics.json"))
    }

    func testQueueNamesAndPreferencesUseByteExactScopesAcrossRelaunch() throws {
        try withStorage { defaults, _ in
            let names = QueueNameStore(defaults: defaults)
            names.save(["first"], scope: composedScope)
            names.save(["second"], scope: decomposedScope)
            let preferences = QueueWorkspacePreferenceStore(defaults: defaults)
            preferences.save(QueueWorkspacePreference(refreshInterval: 30, selectedQueueName: "first", selectedView: "runs"), scope: composedScope)
            preferences.save(QueueWorkspacePreference(refreshInterval: 60, selectedQueueName: "second", selectedView: "metrics"), scope: decomposedScope)
            XCTAssertEqual(QueueNameStore(defaults: defaults).load(scope: composedScope), ["first"])
            XCTAssertEqual(QueueNameStore(defaults: defaults).load(scope: decomposedScope), ["second"])
            XCTAssertEqual(QueueWorkspacePreferenceStore(defaults: defaults).load(scope: composedScope)?.selectedQueueName, "first")
            XCTAssertEqual(QueueWorkspacePreferenceStore(defaults: defaults).load(scope: decomposedScope)?.selectedQueueName, "second")
        }
    }

    func testLegacyScopesAreReadAndMigratedOnlyOnExactUTF8Match() throws {
        try withStorage { defaults, _ in
            let asciiScope = "localhost:6379/0:bull"
            let existing = QueueSummary(name: "first", displayName: "My old label", groupName: "My old group", prefix: "café", counts: .empty, health: .unknown)
            let preference = QueueWorkspacePreference(refreshInterval: 30, selectedQueueName: "first", selectedView: "runs")
            defaults.set(try JSONEncoder().encode([composedScope: ["first"], asciiScope: ["ascii"]]), forKey: "redis.connection.queue.names")
            defaults.set(try JSONEncoder().encode([composedScope: [existing], asciiScope: [QueueSummary(name: "ascii", prefix: "bull", counts: .empty, health: .unknown)]]), forKey: "redis.connection.queue.metadata")
            defaults.set(try JSONEncoder().encode([composedScope: preference, asciiScope: preference]), forKey: "redis.connection.workspace.preference")
            let names = QueueNameStore(defaults: defaults)
            let metadata = QueueMetadataStore(defaults: defaults)
            let preferences = QueueWorkspacePreferenceStore(defaults: defaults)

            XCTAssertEqual(names.load(scope: composedScope), ["first"])
            XCTAssertEqual(metadata.load(scope: composedScope), [existing])
            XCTAssertEqual(preferences.load(scope: composedScope), preference)
            XCTAssertTrue(names.load(scope: decomposedScope).isEmpty)
            XCTAssertTrue(metadata.load(scope: decomposedScope).isEmpty)
            XCTAssertNil(preferences.load(scope: decomposedScope))

            // Writing the NFD scope must leave its NFC legacy neighbor untouched.
            names.save(["second"], scope: decomposedScope)
            try metadata.saveImportedQueues([QueueSummary(name: "second", prefix: "cafe\u{301}", counts: .empty, health: .unknown)], scope: decomposedScope)
            preferences.save(QueueWorkspacePreference(refreshInterval: 60, selectedQueueName: "second", selectedView: "metrics"), scope: decomposedScope)
            XCTAssertEqual(names.load(scope: composedScope), ["first"])
            XCTAssertEqual(metadata.load(scope: composedScope), [existing])
            XCTAssertEqual(preferences.load(scope: composedScope), preference)

            // A subsequent write lazily migrates that exact NFC legacy scope.
            names.save(names.load(scope: composedScope), scope: composedScope)
            try metadata.saveImportedQueues(metadata.load(scope: composedScope), scope: composedScope)
            preferences.save(try XCTUnwrap(preferences.load(scope: composedScope)), scope: composedScope)
            XCTAssertEqual(metadata.load(scope: composedScope), [existing])
            XCTAssertEqual(names.load(scope: decomposedScope), ["second"])
            XCTAssertEqual(metadata.load(scope: decomposedScope).map(\.name), ["second"])
            XCTAssertEqual(preferences.load(scope: decomposedScope)?.refreshInterval, 60)
            XCTAssertEqual(names.load(scope: asciiScope), ["ascii"])
            XCTAssertEqual(metadata.load(scope: asciiScope).map(\.name), ["ascii"])
            XCTAssertEqual(preferences.load(scope: asciiScope), preference)

            for key in ["redis.connection.queue.names", "redis.connection.queue.metadata", "redis.connection.workspace.preference"] {
                let data = try XCTUnwrap(defaults.data(forKey: key))
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(object.count, 3)
                XCTAssertFalse(object.keys.contains { $0.utf8.elementsEqual(composedScope.utf8) })
                XCTAssertEqual(object.keys.filter { $0.hasPrefix("queuescope-scope-v2|") }.count, 2)
            }
        }
    }

    func testMetricFilteringAndRetentionKeepCanonicallyEquivalentScopesSeparate() throws {
        try withStorage { defaults, file in
            let store = MetricSnapshotStore(fileURL: file, legacyDefaults: defaults)
            let series = BullMQMetricSeries(count: 1, previousTimestamp: nil, previousCount: 0, data: [1])
            let native = BullMQNativeMetrics(completed: series, failed: series)
            for index in 0..<121 {
                for scope in [composedScope, decomposedScope] {
                    try store.append(QueueMetricSnapshot(connectionScope: scope, queueName: "email", capturedAt: Date(timeIntervalSince1970: Double(index)), counts: QueueCountsSnapshot(counts: .empty), nativeMetrics: native))
                }
            }
            let relaunched = MetricSnapshotStore(fileURL: file, legacyDefaults: defaults)
            for scope in [composedScope, decomposedScope] {
                let snapshots = try relaunched.load(scope: scope)
                XCTAssertEqual(snapshots.count, 120)
                XCTAssertEqual(snapshots.compactMap(\.nativeMetrics).count, 1)
                XCTAssertTrue(snapshots.allSatisfy { $0.connectionScope?.utf8.elementsEqual(scope.utf8) == true })
            }
        }
    }
}

private func catalogData(_ queues: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schema": "queuescope.queue-catalog", "version": 1, "queues": queues], options: [.sortedKeys])
}

private func catalogFixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("tests/catalog").appendingPathComponent(name))
}

private final class CatalogTestEngine: BullMQEngine, @unchecked Sendable {
    var requests = 0
    func connect(_ config: RedisConnectionConfig) async throws { requests += 1 }
    func disconnect() async { requests += 1 }
    func discoverQueues(prefix: String, cursor: String) async throws -> QueueDiscovery {
        requests += 1
        return QueueDiscovery(names: [], nextCursor: "0")
    }
    func getQueueOverview(queueName: String, prefix: String) async throws -> QueueSummary {
        requests += 1
        return QueueSummary(name: queueName, prefix: prefix, counts: .empty, health: .unknown)
    }
    func getMetrics(queueName: String, prefix: String) async throws -> [QueueMetricSnapshot] { requests += 1; return [] }
    func getWorkers(queueName: String, prefix: String) async throws -> [WorkerSummary] { requests += 1; return [] }
    func getSchedulers(queueName: String, prefix: String) async throws -> [SchedulerSummary] { requests += 1; return [] }
    func getRecentJobs(queueName: String, prefix: String, states: [BullMQState], perStateLimit: Int, totalLimit: Int) async throws -> [JobSummary] { requests += 1; return [] }
    func getJobs(queueName: String, prefix: String, state: BullMQState, page: Int, pageSize: Int) async throws -> JobPage {
        requests += 1
        return JobPage(jobs: [], total: 0, page: page, pageSize: pageSize)
    }
    func findJob(queueName: String, prefix: String, jobID: String) async throws -> JobSummary? { requests += 1; return nil }
    func searchJobs(queueName: String, prefix: String, state: BullMQState?, filter: JobFilter, cursor: JobSearchCursor) async throws -> JobSearchResult { requests += 1; return JobSearchResult(jobs: [], next: nil, scanned: 0) }
    func getJobFlow(_ reference: JobReference) async throws -> JobFlow { requests += 1; return JobFlow() }
    func getJobLogs(queueName: String, prefix: String, jobID: String, start: Int?, limit: Int) async throws -> JobLogs { requests += 1; return .empty }
    func getJobDetail(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws -> JobDetail { throw unexpectedMutation() }
    func setQueuePaused(queueName: String, prefix: String, paused: Bool) async throws { throw unexpectedMutation() }
    func retryJob(queueName: String, prefix: String, jobID: String, state: BullMQState) async throws { throw unexpectedMutation() }
    func removeJob(queueName: String, prefix: String, jobID: String, removeChildren: Bool) async throws { throw unexpectedMutation() }
    func promoteJob(queueName: String, prefix: String, jobID: String) async throws { throw unexpectedMutation() }
    func duplicateJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String { throw unexpectedMutation() }
    func addJob(queueName: String, prefix: String, name: String, data: AnySendableJSON, options: AnySendableJSON) async throws -> String { throw unexpectedMutation() }
    func cleanJobs(queueName: String, prefix: String, state: BullMQState, grace: Int, limit: Int) async throws -> Int { throw unexpectedMutation() }
    func getSchedulerPreview(queueName: String, prefix: String, key: String, timeZone: String?) async throws -> SchedulerPreview { throw unexpectedMutation() }
    func removeScheduler(queueName: String, prefix: String, key: String, kind: String) async throws { throw unexpectedMutation() }
    private func unexpectedMutation() -> Error {
        requests += 1
        XCTFail("Catalog import must not call Redis actions")
        return BullMQDashboardError.redis("Unexpected action")
    }
}
