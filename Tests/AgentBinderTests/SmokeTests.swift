import AgentBinder
import Testing

@Test func versionIsSemver() {
    #expect(AgentBinder.version.wholeMatch(of: /\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?/) != nil)
}
