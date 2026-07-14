import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // 首次启动直接展示完整收录目录；搜索后仍会自动进入单字详情。
    @Published var section: AppSection = .catalog
    @Published var query = ""
    @Published var character: CharacterRecord?
    @Published var hasSearched = false
    @Published var selectedPeriod = "全部"
    @Published var recognitionImageURL: URL?
    @Published var recognitionImage: NSImage?
    @Published var recognition: OCRResponse?
    @Published var resolvedCandidates: [ResolvedCandidate] = []
    @Published var isRecognizing = false
    @Published var alertMessage: String?
    @Published private(set) var catalogCharacters: [CharacterSummary] = []
    @Published private(set) var canGoBack = false

    private let database: DatabaseStore
    private var navigationHistory: [NavigationSnapshot] = []

    private struct NavigationSnapshot {
        let section: AppSection
        let query: String
        let character: CharacterRecord?
        let hasSearched: Bool
        let selectedPeriod: String
    }

    init() {
        do {
            let store = try DatabaseStore()
            database = store
            catalogCharacters = try store.catalogCharacters()
        } catch {
            fatalError(error.localizedDescription)
        }
    }

    var filteredCatalog: [CharacterSummary] {
        let cleaned = query.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return catalogCharacters }
        let tokens = Array(cleaned).map(String.init)
        return catalogCharacters.filter { summary in
            summary.searchableText.contains(cleaned)
                || tokens.contains { summary.searchableText.contains($0) }
        }
    }

    var featuredCatalog: [CharacterSummary] {
        Array(catalogCharacters.prefix(18))
    }

    var periods: [String] {
        guard let character else { return ["全部"] }
        var seen = Set<String>()
        return ["全部"] + character.glyphs.map(\.period).filter { seen.insert($0).inserted }
    }

    var visibleGlyphs: [GlyphRecord] {
        guard let character else { return [] }
        return selectedPeriod == "全部"
            ? character.glyphs
            : character.glyphs.filter { $0.period == selectedPeriod }
    }

    func search() {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            character = nil
            hasSearched = false
            return
        }
        do {
            character = try database.search(query)
            selectedPeriod = "全部"
            hasSearched = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func submitSearch() {
        if section != .lookup {
            pushCurrentPage()
        }
        section = .lookup
        search()
    }

    func updateQuery(_ value: String) {
        query = value
        character = nil
        selectedPeriod = "全部"
        hasSearched = false
    }

    func openCharacter(_ summary: CharacterSummary) {
        pushCurrentPage()
        query = summary.normalizedChar
        section = .lookup
        search()
    }

    func openCandidate(_ candidate: ResolvedCandidate) {
        guard let token = candidate.normalizedChar ?? (
            candidate.candidate.labelName.count == 1 ? candidate.candidate.labelName : nil
        ) else { return }
        pushCurrentPage()
        query = token
        section = .lookup
        search()
    }

    func showCatalog() {
        guard section != .catalog else { return }
        pushCurrentPage()
        section = .catalog
        query = ""
        character = nil
        hasSearched = false
        selectedPeriod = "全部"
    }

    func showRecognition() {
        guard section != .recognition else { return }
        pushCurrentPage()
        section = .recognition
    }

    func goBack() {
        guard let previous = navigationHistory.popLast() else { return }
        section = previous.section
        query = previous.query
        character = previous.character
        hasSearched = previous.hasSearched
        selectedPeriod = previous.selectedPeriod
        canGoBack = !navigationHistory.isEmpty
    }

    private func pushCurrentPage() {
        navigationHistory.append(
            NavigationSnapshot(
                section: section,
                query: query,
                character: character,
                hasSearched: hasSearched,
                selectedPeriod: selectedPeriod
            )
        )
        if navigationHistory.count > 24 {
            navigationHistory.removeFirst(navigationHistory.count - 24)
        }
        canGoBack = true
    }

    func chooseRecognitionImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recognitionImageURL = url
        recognitionImage = NSImage(contentsOf: url)
        recognition = nil
        resolvedCandidates = []
    }

    func recognize() {
        guard let recognitionImageURL else { return }
        isRecognizing = true
        recognition = nil
        resolvedCandidates = []
        Task {
            do {
                let response = try await OCRService.recognize(imageURL: recognitionImageURL)
                recognition = response
                if let candidates = response.detections.first?.candidates {
                    resolvedCandidates = try candidates.map { try database.resolve($0) }
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            isRecognizing = false
        }
    }

    func saveEntry(_ draft: EntryDraft) throws {
        let characterId: Int64
        if let existingId = draft.characterId {
            guard draft.imageURL != nil else {
                throw AppError.message("请选择字形图片")
            }
            characterId = existingId
        } else {
            characterId = try database.createCharacter(
                normalizedChar: draft.normalizedChar,
                simplifiedChar: draft.simplifiedChar,
                traditionalChar: draft.traditionalChar,
                variants: draft.variants
                    .replacingOccurrences(of: "，", with: ",")
                    .split(separator: ",")
                    .map(String.init),
                explanation: draft.explanation
            )
        }
        if let imageURL = draft.imageURL {
            try database.addGlyph(
                characterId: characterId,
                period: draft.period,
                sourceURL: imageURL,
                source: draft.source,
                sourceNumber: draft.sourceNumber,
                transcription: draft.transcription,
                confidence: Double(draft.confidence),
                notes: draft.notes
            )
        }
        pushCurrentPage()
        query = draft.normalizedChar
        section = .lookup
        catalogCharacters = try database.catalogCharacters()
        search()
    }
}

struct EntryDraft {
    var characterId: Int64?
    var normalizedChar = ""
    var simplifiedChar = ""
    var traditionalChar = ""
    var variants = ""
    var explanation = ""
    var period = "甲骨文"
    var imageURL: URL?
    var source = ""
    var sourceNumber = ""
    var transcription = ""
    var confidence = ""
    var notes = ""

    init(character: CharacterRecord? = nil) {
        characterId = character?.id
        normalizedChar = character?.normalizedChar ?? ""
        simplifiedChar = character?.simplifiedChar ?? ""
        traditionalChar = character?.traditionalChar ?? ""
        variants = character?.variants.joined(separator: "，") ?? ""
        explanation = character?.explanation ?? ""
    }
}
