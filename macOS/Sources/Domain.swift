import CoreFoundation
import Foundation

struct GlyphRecord: Identifiable, Hashable {
    let id: Int64
    let period: String
    let imagePath: String
    let source: String?
    let sourceNumber: String?
    let transcription: String?
    let confidence: Double?
    let notes: String?
    let sourceURL: String?
    let license: String?
}

struct CharacterRecord: Identifiable, Hashable {
    let id: Int64
    let normalizedChar: String
    let simplifiedChar: String?
    let traditionalChar: String?
    let variants: [String]
    let relatedVariants: [String]
    let explanation: String?
    let glyphs: [GlyphRecord]
}

struct OCRCandidate: Codable, Identifiable, Hashable {
    let classId: Int
    let labelName: String
    let confidence: Double

    var id: Int { classId }
}

struct OCRDetection: Codable, Identifiable, Hashable {
    let bbox: [Int]
    let detectionConfidence: Double?
    let candidates: [OCRCandidate]

    var id: String { bbox.map(String.init).joined(separator: "-") }
}

struct OCRResponse: Codable, Hashable {
    let device: String
    let usedFullImageFallback: Bool
    let confidenceNotice: String
    let detections: [OCRDetection]
}

struct ResolvedCandidate: Identifiable, Hashable {
    let candidate: OCRCandidate
    let normalizedChar: String?
    let characterId: Int64?

    var id: Int { candidate.classId }
}

struct RecognitionLabelSeed: Codable {
    let classId: Int
    let labelName: String
    let normalizedChar: String?
    let notes: String?
}

struct BundledGlyphSeed: Codable {
    let character: String
    let period: String
    let asset: String
    let source: String
    let sourceNumber: String
    let sourceURL: String
    let transcription: String
    let license: String
    let notes: String
    let rank: Int
}

struct CharacterMetadataSeed: Codable {
    let character: String
    let directVariants: [String]
    let relatedVariants: [String]
    let definition: String?
    let chineseDefinition: String?
    let definitionSource: String?
}

struct CharacterSummary: Identifiable, Hashable {
    let id: Int64
    let normalizedChar: String
    let simplifiedChar: String?
    let traditionalChar: String?
    let variants: [String]
    let glyphCount: Int
    let periods: [String]
    let previewImagePath: String

    var searchableText: String {
        ([normalizedChar, simplifiedChar, traditionalChar]
            .compactMap { $0 } + variants).joined()
    }
}

enum AppSection: Hashable {
    case lookup
    case catalog
    case recognition
}

/// 只轉換介面與資料說明的顯示文字；資料庫鍵、搜尋別名與模型標籤維持原值。
enum AppDisplay {
    static func localized(
        simplified: String,
        traditional: String,
        usesTraditional: Bool
    ) -> String {
        usesTraditional ? traditional : simplified
    }

    static func period(_ rawValue: String, usesTraditional: Bool = true) -> String {
        usesTraditional && rawValue == "战国文字" ? "戰國文字" : rawValue
    }

    static func traditional(_ rawValue: String) -> String {
        if let converted = transformed(rawValue, using: "Simplified-Traditional") {
            return converted
        }
        return [
            ("战国", "戰國"),
            ("简帛", "簡帛"),
            ("秦简", "秦簡"),
            ("《说文》", "《說文》"),
            ("公有领域", "公有領域"),
            ("未细分年代", "未細分年代"),
            ("模型候选", "模型候選"),
            ("未经校准", "未經校準"),
            ("不是确定释读", "並非確定釋讀")
        ].reduce(rawValue) { value, replacement in
            value.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    /// macOS 內建 ICU 轉寫只用於顯示，不會改寫原始釋義或搜尋資料。
    static func content(_ rawValue: String, usesTraditional: Bool) -> String {
        guard !usesTraditional else { return traditional(rawValue) }
        return transformed(rawValue, using: "Traditional-Simplified") ?? rawValue
    }

    private static func transformed(_ value: String, using identifier: String) -> String? {
        let mutable = NSMutableString(string: value)
        guard CFStringTransform(mutable, nil, identifier as CFString, false) else {
            return nil
        }
        return mutable as String
    }
}

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
