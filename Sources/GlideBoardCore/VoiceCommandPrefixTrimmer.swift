import Foundation

enum VoiceCommandPrefixTrimResult: Equatable {
    case success(String)
    case unsafe
}

enum VoiceCommandPrefixTrimmer {
    static func trim(_ transcript: DictationTranscript,
                     wakeWord: String,
                     estimatedCommandEnd: TimeInterval) -> VoiceCommandPrefixTrimResult
    {
        guard validate(transcript) else { return .unsafe }
        let normalized = transcript.words.map {
            VoiceAttentionIntentMatcher.normalize($0.text)
        }
        let wake = VoiceAttentionIntentMatcher.normalize(wakeWord)
        let candidates = [
            [wake, "graba", "audio"],
            ["graba", "audio"],
            [wake, "graba", "el", "audio"],
        ]
        guard let length = candidates.first(where: {
            normalized.count >= $0.count && Array(normalized.prefix($0.count)) == $0
        })?.count else {
            return .unsafe
        }

        let lastWord = transcript.words[length - 1]
        guard lastWord.end <= estimatedCommandEnd + 0.250 else { return .unsafe }
        let nsText = transcript.text as NSString
        var remainder = nsText.substring(from: lastWord.textRangeUTF16.upperBound)
        remainder = removeLeadingCommandDelimiter(from: remainder)
        return .success(remainder)
    }

    private static func validate(_ transcript: DictationTranscript) -> Bool {
        let nsText = transcript.text as NSString
        var previousRangeEnd = 0
        var previousTimeEnd: TimeInterval = 0
        for word in transcript.words {
            let range = word.textRangeUTF16
            guard range.lowerBound >= previousRangeEnd,
                  range.lowerBound >= 0,
                  range.upperBound >= range.lowerBound,
                  range.upperBound <= nsText.length,
                  word.start >= previousTimeEnd,
                  word.end >= word.start else { return false }
            let source = nsText.substring(with: NSRange(location: range.lowerBound,
                                                        length: range.count))
            guard VoiceAttentionIntentMatcher.normalize(source)
                    == VoiceAttentionIntentMatcher.normalize(word.text) else { return false }
            previousRangeEnd = range.upperBound
            previousTimeEnd = word.end
        }
        return !transcript.words.isEmpty
    }

    private static func removeLeadingCommandDelimiter(from text: String) -> String {
        var value = text
        value = String(value.drop(while: { $0.isWhitespace }))
        if let first = value.first, ",:;—–-".contains(first) {
            value.removeFirst()
            value = String(value.drop(while: { $0.isWhitespace }))
        }
        return value
    }
}
