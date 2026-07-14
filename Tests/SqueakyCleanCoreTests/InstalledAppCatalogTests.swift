import Foundation
import Testing
@testable import SqueakyCleanCore

struct InstalledAppCatalogTests {
    @Test
    func overlappingSearchRootsDoNotDuplicateTheSameApplication() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let applications = sandbox.url.appendingPathComponent("Applications", isDirectory: true)
        let utilities = applications.appendingPathComponent("Utilities", isDirectory: true)
        _ = try makeApplicationBundle(
            in: utilities,
            name: "Fixture Tool",
            bundleIdentifier: "com.example.fixture-tool"
        )

        let snapshot = InstalledAppCatalog(
            searchRoots: [applications, utilities],
            currentApplicationBundle: nil
        ).snapshot()

        #expect(snapshot.count == 1)
        #expect(snapshot.first?.bundleIdentifier == "com.example.fixture-tool")
    }

    @Test
    func duplicateBundleIdentifiersAtDifferentLocationsAreCollapsed() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let systemApplications = sandbox.url.appendingPathComponent("System Applications", isDirectory: true)
        let userApplications = sandbox.url.appendingPathComponent("User Applications", isDirectory: true)
        _ = try makeApplicationBundle(
            in: systemApplications,
            name: "Fixture Tool",
            bundleIdentifier: "com.example.fixture-tool"
        )
        _ = try makeApplicationBundle(
            in: userApplications,
            name: "Fixture Tool Copy",
            bundleIdentifier: "COM.EXAMPLE.FIXTURE-TOOL"
        )

        let snapshot = InstalledAppCatalog(
            searchRoots: [systemApplications, userApplications],
            currentApplicationBundle: nil
        ).snapshot()

        #expect(snapshot.count == 1)
    }

    @Test
    func runningApplicationOutsideSearchRootsIsIncluded() throws {
        let sandbox = try TemporaryDirectory()
        defer { sandbox.remove() }

        let downloads = sandbox.url.appendingPathComponent("Downloads", isDirectory: true)
        let appURL = try makeApplicationBundle(
            in: downloads,
            name: "Running Fixture",
            bundleIdentifier: "com.example.running-fixture"
        )
        let runningBundle = try #require(Bundle(url: appURL))

        let snapshot = InstalledAppCatalog(
            searchRoots: [],
            currentApplicationBundle: runningBundle
        ).snapshot()

        let app = try #require(snapshot.first)
        #expect(snapshot.count == 1)
        #expect(app.bundleIdentifier == "com.example.running-fixture")
        #expect(app.bundleURL.standardizedFileURL == appURL.standardizedFileURL)
    }

    private func makeApplicationBundle(
        in directory: URL,
        name: String,
        bundleIdentifier: String
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }
}
