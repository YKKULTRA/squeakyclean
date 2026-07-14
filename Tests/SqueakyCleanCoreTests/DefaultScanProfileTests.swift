import Foundation
import Testing
@testable import SqueakyCleanCore

struct DefaultScanProfileTests {
    @Test
    func standardRootsStayUserScoped() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/Users/test/tmp", isDirectory: true)
        let roots = DefaultScanProfile.roots(
            homeDirectory: home,
            temporaryDirectory: temporary
        )

        let standardRoots = roots.filter { $0.minimumScope == .standard }

        #expect(standardRoots.count == 6)
        #expect(standardRoots.allSatisfy { root in
            let path = root.url.standardizedFileURL.path
            return path == temporary.path || path.hasPrefix(home.path + "/")
        })
        #expect(standardRoots.allSatisfy { !$0.url.standardizedFileURL.path.hasPrefix("/Library/") })
    }

    @Test
    func everySystemWideRootRequiresDeepScope() {
        let roots = DefaultScanProfile.roots(
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            temporaryDirectory: URL(fileURLWithPath: "/Users/test/tmp", isDirectory: true)
        )
        let systemWideRoots = roots.filter {
            let path = $0.url.standardizedFileURL.path
            return path == "/Library" || path.hasPrefix("/Library/")
        }

        #expect(systemWideRoots.count == 6)
        #expect(systemWideRoots.allSatisfy { $0.minimumScope == .deep })
        #expect(systemWideRoots.contains { $0.url.standardizedFileURL.path == "/Library/Receipts" })
    }
}
