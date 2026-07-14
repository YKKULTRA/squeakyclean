import Foundation
import Testing
@testable import SqueakyCleanCore

struct PermissionCoordinatorTests {
    @Test
    func fullDiskAccessStatusIsSeparateFromScanRootReadability() {
        let readableRoot = InventoryRoot(
            name: "User Caches",
            url: URL(fileURLWithPath: "/Users/test/Library/Caches"),
            artifactKind: .cache,
            minimumScope: .standard
        )
        let coordinator = PermissionCoordinator(
            accessProbe: { _ in .granted },
            fullDiskAccessProbe: { .notGranted("Protected probe denied") }
        )

        let state = coordinator.evaluate(for: [readableRoot], scope: .standard)

        #expect(state.scanRootsReadable == true)
        #expect(state.fullDiskAccessStatus == .notGranted("Protected probe denied"))
    }

    @Test
    func fullDiskAccessStatusCanBeUnknownWithoutBlockingNormalScans() {
        let readableRoot = InventoryRoot(
            name: "User Logs",
            url: URL(fileURLWithPath: "/Users/test/Library/Logs"),
            artifactKind: .log,
            minimumScope: .standard
        )
        let coordinator = PermissionCoordinator(
            accessProbe: { _ in .granted },
            fullDiskAccessProbe: { .unknown("No protected probe path was available") }
        )

        let state = coordinator.evaluate(for: [readableRoot], scope: .standard)

        #expect(state.scanRootsReadable == true)
        #expect(state.fullDiskAccessStatus == .unknown("No protected probe path was available"))
    }
}
