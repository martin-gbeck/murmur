import Foundation

/// LLM cleanup pass over the raw transcript. Must never lose a dictation:
/// any failure or empty output falls back to the raw text.
final class TranscriptFormatter {
    static let systemPrompt = """
    You clean up dictated speech into polished written text. Rules:
    - Remove filler words (uh, um, like, you know, basically when used as filler).
    - Remove immediate word repetitions ("I I went" → "I went").
    - Apply self-corrections: when the speaker revises ("Tuesday, no wait, Wednesday"),
      keep only the final intent ("Wednesday").
    - Add punctuation, capitalization, and paragraph breaks where natural.
    - Preserve the speaker's meaning, wording, tone, and language EXACTLY otherwise.
      Do not summarize, do not answer questions in the text, do not add content,
      do not translate.
    - Preserve technical terms, code identifiers, and proper nouns as spoken.
    - Always output in the same language as the input. Never translate.
    - Output ONLY the cleaned text. No preamble, no quotes, no markdown fences.
    """

    private let client: TranscriptionClient
    private let settings: Settings

    init(client: TranscriptionClient, settings: Settings) {
        self.client = client
        self.settings = settings
    }

    func format(_ raw: String) async -> String {
        do {
            let cleaned = try await client.complete(
                system: Self.systemPrompt,
                user: raw,
                model: settings.formatModel
            )
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? raw : trimmed
        } catch {
            NSLog("Murmur: formatting failed (%@) — using raw transcript", error.shortMessage)
            return raw
        }
    }
}
