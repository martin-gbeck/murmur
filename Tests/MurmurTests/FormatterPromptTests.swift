import Foundation
import Testing
@testable import Murmur

private final class MockClient: TranscriptionClient {
    var completeResult: Result<String, Error> = .success("")
    var receivedSystem: String?
    var receivedUser: String?
    var receivedModel: String?

    func transcribe(_ audio: URL) async throws -> String {
        fatalError("not used in formatter tests")
    }

    func complete(system: String, user: String, model: String) async throws -> String {
        receivedSystem = system
        receivedUser = user
        receivedModel = model
        return try completeResult.get()
    }
}

@Suite struct FormatterPromptTests {
    private func makeFixture(suite: String) -> (MockClient, TranscriptFormatter, Settings) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults)
        let client = MockClient()
        return (client, TranscriptFormatter(client: client, settings: settings), settings)
    }

    @Test func sendsSystemPromptRawTextAndConfiguredModel() async {
        let (client, formatter, settings) = makeFixture(suite: "murmur.fmt.send")
        client.completeResult = .success("Cleaned.")
        settings.formatModel = "gpt-4o-mini"
        let result = await formatter.format("um, raw text")
        #expect(result == "Cleaned.")
        #expect(client.receivedSystem == TranscriptFormatter.systemPrompt)
        #expect(client.receivedUser == "um, raw text")
        #expect(client.receivedModel == "gpt-4o-mini")
    }

    @Test func promptContainsTheCoreRules() {
        let prompt = TranscriptFormatter.systemPrompt
        #expect(prompt.contains("Remove filler words"))
        #expect(prompt.contains("self-corrections"))
        #expect(prompt.contains("Never translate"))
        #expect(prompt.contains("Output ONLY the cleaned text"))
    }

    @Test func failureFallsBackToRaw() async {
        let (client, formatter, _) = makeFixture(suite: "murmur.fmt.fail")
        client.completeResult = .failure(APIError("Formatting failed: 500"))
        let result = await formatter.format("the raw transcript")
        #expect(result == "the raw transcript")
    }

    @Test func emptyOutputFallsBackToRaw() async {
        let (client, formatter, _) = makeFixture(suite: "murmur.fmt.empty")
        client.completeResult = .success("   \n  ")
        let result = await formatter.format("the raw transcript")
        #expect(result == "the raw transcript")
    }

    @Test func outputIsTrimmed() async {
        let (client, formatter, _) = makeFixture(suite: "murmur.fmt.trim")
        client.completeResult = .success("\n Cleaned text. \n")
        let result = await formatter.format("raw")
        #expect(result == "Cleaned text.")
    }
}
