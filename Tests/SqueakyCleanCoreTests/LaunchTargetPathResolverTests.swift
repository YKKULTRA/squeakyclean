import Foundation
import Testing
@testable import SqueakyCleanCore

struct LaunchTargetPathResolverTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test
    func tildeExpandsToHome() {
        let resolver = LaunchTargetPathResolver(homeDirectory: home, environment: [:])
        #expect(resolver.resolve("~/bin/agent") == "/Users/test/bin/agent")
        #expect(resolver.resolve("~") == "/Users/test")
    }

    @Test
    func tildeWithUnknownUserIsLeftAlone() {
        let resolver = LaunchTargetPathResolver(homeDirectory: home, environment: [:])
        // We do not implement ~user resolution; LaunchAgents almost never use it.
        #expect(resolver.resolve("~bob/bin/agent") == "~bob/bin/agent")
    }

    @Test
    func bracedAndUnbracedEnvironmentVariablesExpand() {
        let resolver = LaunchTargetPathResolver(
            homeDirectory: home,
            environment: ["HOME": "/Users/test", "USER": "test"]
        )
        #expect(resolver.resolve("$HOME/bin") == "/Users/test/bin")
        #expect(resolver.resolve("${HOME}/bin") == "/Users/test/bin")
        #expect(resolver.resolve("/users/${USER}/bin") == "/users/test/bin")
    }

    @Test
    func unknownEnvironmentVariableIsPreservedVerbatim() {
        let resolver = LaunchTargetPathResolver(homeDirectory: home, environment: [:])
        #expect(resolver.resolve("$UNSET/agent") == "$UNSET/agent")
        #expect(resolver.resolve("${ALSO_UNSET}/agent") == "${ALSO_UNSET}/agent")
    }

    @Test
    func plainPathIsUnchanged() {
        let resolver = LaunchTargetPathResolver(homeDirectory: home, environment: [:])
        #expect(resolver.resolve("/usr/local/bin/agent") == "/usr/local/bin/agent")
    }

    @Test
    func loneDollarSignIsPreserved() {
        let resolver = LaunchTargetPathResolver(homeDirectory: home, environment: [:])
        #expect(resolver.resolve("/tmp/$") == "/tmp/$")
    }
}
