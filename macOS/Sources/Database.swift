import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class DatabaseStore {
    private var db: OpaquePointer?
    let rootDirectory: URL
    let glyphDirectory: URL

    init() throws {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        rootDirectory = support.appendingPathComponent("AncientOCR", isDirectory: true)
        glyphDirectory = rootDirectory.appendingPathComponent("Glyphs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: glyphDirectory,
            withIntermediateDirectories: true
        )

        let databaseURL = rootDirectory.appendingPathComponent("ancient_ocr.sqlite3")
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw AppError.message("数据库无法打开")
        }
        try execute(schema)
        try ensureGlyphColumns()
        try ensureCharacterColumns()
        try seedRecognitionLabelsIfNeeded()
        try seedSearchableCharactersIfNeeded()
        try seedBundledGlyphCatalogIfNeeded()
        try seedCharacterMetadataIfNeeded()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func search(_ rawQuery: String) throws -> CharacterRecord? {
        let query = rawQuery.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let sql = """
        SELECT c.id, c.normalized_char, c.simplified_char,
               c.traditional_char, c.variants, c.related_variants, c.explanation
        FROM character_aliases a
        JOIN characters c ON c.id = a.character_id
        WHERE a.alias = ?
        LIMIT 1
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(query, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let id = sqlite3_column_int64(statement, 0)
        let variantsData = text(statement, 4) ?? "[]"
        let variants = (try? JSONDecoder().decode(
            [String].self,
            from: Data(variantsData.utf8)
        )) ?? []
        let relatedData = text(statement, 5) ?? "[]"
        let relatedVariants = (try? JSONDecoder().decode(
            [String].self,
            from: Data(relatedData.utf8)
        )) ?? []
        return CharacterRecord(
            id: id,
            normalizedChar: text(statement, 1) ?? "",
            simplifiedChar: text(statement, 2),
            traditionalChar: text(statement, 3),
            variants: variants,
            relatedVariants: relatedVariants,
            explanation: text(statement, 6),
            glyphs: try glyphs(for: id)
        )
    }

    /// Returns only characters that have real glyph images, in the curated catalog order.
    func catalogCharacters() throws -> [CharacterSummary] {
        let statement = try prepare("""
            SELECT c.id, c.normalized_char, c.simplified_char, c.traditional_char,
                   c.variants, COUNT(g.id), GROUP_CONCAT(DISTINCT g.period),
                   (
                       SELECT gx.image_path FROM glyphs gx
                       WHERE gx.character_id = c.id
                       ORDER BY CASE gx.period
                           WHEN '甲骨文' THEN 1
                           WHEN '金文' THEN 2
                           WHEN '战国文字' THEN 3
                           WHEN '小篆' THEN 4
                           ELSE 99 END, gx.id
                       LIMIT 1
                   )
            FROM characters c
            JOIN glyphs g ON g.character_id = c.id
            LEFT JOIN catalog_characters cc ON cc.character_id = c.id
            GROUP BY c.id
            ORDER BY COALESCE(cc.rank, 999999), c.id
            """)
        defer { sqlite3_finalize(statement) }
        let periodOrder = ["甲骨文": 1, "金文": 2, "战国文字": 3, "小篆": 4]
        var output: [CharacterSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let variantsData = text(statement, 4) ?? "[]"
            let variants = (try? JSONDecoder().decode(
                [String].self,
                from: Data(variantsData.utf8)
            )) ?? []
            let periods = (text(statement, 6) ?? "")
                .split(separator: ",")
                .map(String.init)
                .sorted { periodOrder[$0, default: 99] < periodOrder[$1, default: 99] }
            output.append(CharacterSummary(
                id: sqlite3_column_int64(statement, 0),
                normalizedChar: text(statement, 1) ?? "",
                simplifiedChar: text(statement, 2),
                traditionalChar: text(statement, 3),
                variants: variants,
                glyphCount: Int(sqlite3_column_int(statement, 5)),
                periods: periods,
                previewImagePath: text(statement, 7) ?? ""
            ))
        }
        return output
    }

    @discardableResult
    func createCharacter(
        normalizedChar: String,
        simplifiedChar: String,
        traditionalChar: String,
        variants: [String],
        explanation: String
    ) throws -> Int64 {
        let normalized = normalize(normalizedChar)
        guard !normalized.isEmpty else { throw AppError.message("请输入规范字") }
        let simplified = optionalNormalize(simplifiedChar)
        let traditional = optionalNormalize(traditionalChar)
        let cleanVariants = Array(Set(variants.map(normalize).filter { !$0.isEmpty })).sorted()
        let variantsJSON = String(
            data: try JSONEncoder().encode(cleanVariants),
            encoding: .utf8
        ) ?? "[]"

        try execute("BEGIN IMMEDIATE")
        do {
            let insert = try prepare("""
                INSERT INTO characters(
                    normalized_char, simplified_char, traditional_char, variants, explanation
                ) VALUES (?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            bind(normalized, to: insert, at: 1)
            bind(simplified, to: insert, at: 2)
            bind(traditional, to: insert, at: 3)
            bind(variantsJSON, to: insert, at: 4)
            bind(optionalNormalize(explanation), to: insert, at: 5)
            try stepDone(insert)
            let characterId = sqlite3_last_insert_rowid(db)

            var aliases: [(String, String)] = [(normalized, "normalized")]
            if let simplified { aliases.append((simplified, "simplified")) }
            if let traditional { aliases.append((traditional, "traditional")) }
            aliases += cleanVariants.map { ($0, "variant") }
            var seen = Set<String>()
            for (alias, kind) in aliases where seen.insert(alias).inserted {
                let aliasInsert = try prepare(
                    "INSERT INTO character_aliases(alias, character_id, alias_type) VALUES (?, ?, ?)"
                )
                bind(alias, to: aliasInsert, at: 1)
                sqlite3_bind_int64(aliasInsert, 2, characterId)
                bind(kind, to: aliasInsert, at: 3)
                defer { sqlite3_finalize(aliasInsert) }
                try stepDone(aliasInsert)
            }
            try execute("COMMIT")
            return characterId
        } catch {
            try? execute("ROLLBACK")
            if sqliteMessage.contains("UNIQUE") {
                throw AppError.message("该字或别名已存在")
            }
            throw error
        }
    }

    func addGlyph(
        characterId: Int64,
        period: String,
        sourceURL: URL,
        source: String,
        sourceNumber: String,
        transcription: String,
        confidence: Double?,
        notes: String
    ) throws {
        let suffix = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let filename = "\(UUID().uuidString).\(suffix)"
        let target = glyphDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: target)
        do {
            let statement = try prepare("""
                INSERT INTO glyphs(
                    character_id, period, image_path, source, source_number,
                    transcription, confidence, notes
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, characterId)
            bind(normalize(period).isEmpty ? "未定" : normalize(period), to: statement, at: 2)
            bind(target.path, to: statement, at: 3)
            bind(optionalNormalize(source), to: statement, at: 4)
            bind(optionalNormalize(sourceNumber), to: statement, at: 5)
            bind(optionalNormalize(transcription), to: statement, at: 6)
            if let confidence {
                sqlite3_bind_double(statement, 7, confidence)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            bind(optionalNormalize(notes), to: statement, at: 8)
            try stepDone(statement)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func resolve(_ candidate: OCRCandidate) throws -> ResolvedCandidate {
        let statement = try prepare("""
            SELECT normalized_char
            FROM recognition_labels
            WHERE class_id = ? AND label_name = ?
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(candidate.classId))
        bind(candidate.labelName, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let normalized = text(statement, 0),
              !normalized.isEmpty else {
            return ResolvedCandidate(candidate: candidate, normalizedChar: nil, characterId: nil)
        }
        let character = try search(normalized)
        return ResolvedCandidate(
            candidate: candidate,
            normalizedChar: normalized,
            characterId: character?.id
        )
    }

    private func glyphs(for characterId: Int64) throws -> [GlyphRecord] {
        let statement = try prepare("""
            SELECT id, period, image_path, source, source_number,
                   transcription, confidence, notes, source_url, license
            FROM glyphs
            WHERE character_id = ?
            ORDER BY CASE period
                WHEN '甲骨文' THEN 1
                WHEN '金文' THEN 2
                WHEN '战国文字' THEN 3
                WHEN '戰國文字' THEN 3
                WHEN '小篆' THEN 4
                ELSE 99 END, period, id
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, characterId)
        var output: [GlyphRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let confidence = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 6)
            output.append(GlyphRecord(
                id: sqlite3_column_int64(statement, 0),
                period: text(statement, 1) ?? "未定",
                imagePath: text(statement, 2) ?? "",
                source: text(statement, 3),
                sourceNumber: text(statement, 4),
                transcription: text(statement, 5),
                confidence: confidence,
                notes: text(statement, 7),
                sourceURL: text(statement, 8),
                license: text(statement, 9)
            ))
        }
        return output
    }

    private func seedRecognitionLabelsIfNeeded() throws {
        let countStatement = try prepare("SELECT COUNT(*) FROM recognition_labels")
        defer { sqlite3_finalize(countStatement) }
        guard sqlite3_step(countStatement) == SQLITE_ROW,
              sqlite3_column_int(countStatement, 0) == 0,
              let url = Bundle.main.url(
                forResource: "recognition_labels",
                withExtension: "json"
              ) else { return }
        let seeds = try JSONDecoder().decode(
            [RecognitionLabelSeed].self,
            from: Data(contentsOf: url)
        )
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO recognition_labels(class_id, normalized_char, label_name, notes)
                VALUES (?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            for seed in seeds {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int(statement, 1, Int32(seed.classId))
                bind(seed.normalizedChar, to: statement, at: 2)
                bind(seed.labelName, to: statement, at: 3)
                bind(seed.notes, to: statement, at: 4)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Turns only real, single CJK labels from the recognizer into searchable entries.
    /// Opaque checkpoint labels and private-use code points stay unmapped deliberately.
    private func seedSearchableCharactersIfNeeded() throws {
        let migrationKey = "searchable_catalog_v2"
        let check = try prepare("SELECT 1 FROM app_meta WHERE key = ? LIMIT 1")
        bind(migrationKey, to: check, at: 1)
        let alreadySeeded = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard !alreadySeeded else { return }

        let labels = try prepare("""
            SELECT class_id, label_name
            FROM recognition_labels
            WHERE normalized_char IS NOT NULL
            ORDER BY class_id
            """)
        var seeds: [(classId: Int32, label: String)] = []
        while sqlite3_step(labels) == SQLITE_ROW {
            guard let label = text(labels, 1), isCJKCharacter(label) else { continue }
            seeds.append((sqlite3_column_int(labels, 0), label))
        }
        sqlite3_finalize(labels)

        try execute("BEGIN IMMEDIATE")
        do {
            for seed in seeds {
                let relation = conservativeCharacterRelation(seed.label)
                var existingCharacterId: Int64?
                for alias in relation.aliases where existingCharacterId == nil {
                    existingCharacterId = try characterId(forAlias: alias)
                }

                if existingCharacterId == nil {
                    let insert = try prepare("""
                        INSERT OR IGNORE INTO characters(
                            normalized_char, simplified_char, traditional_char, variants, explanation
                        ) VALUES (?, ?, ?, '[]', NULL)
                        """)
                    bind(relation.normalized, to: insert, at: 1)
                    bind(relation.simplified, to: insert, at: 2)
                    bind(relation.traditional, to: insert, at: 3)
                    try stepDone(insert)
                    sqlite3_finalize(insert)
                    existingCharacterId = try characterId(forNormalized: relation.normalized)
                }
                guard let characterId = existingCharacterId else { continue }

                let updateCharacter = try prepare("""
                    UPDATE characters
                    SET simplified_char = COALESCE(simplified_char, ?),
                        traditional_char = COALESCE(traditional_char, ?)
                    WHERE id = ?
                    """)
                bind(relation.simplified, to: updateCharacter, at: 1)
                bind(relation.traditional, to: updateCharacter, at: 2)
                sqlite3_bind_int64(updateCharacter, 3, characterId)
                try stepDone(updateCharacter)
                sqlite3_finalize(updateCharacter)

                for alias in relation.aliases {
                    let aliasInsert = try prepare("""
                        INSERT OR IGNORE INTO character_aliases(alias, character_id, alias_type)
                        VALUES (?, ?, 'model')
                        """)
                    bind(alias, to: aliasInsert, at: 1)
                    sqlite3_bind_int64(aliasInsert, 2, characterId)
                    try stepDone(aliasInsert)
                    sqlite3_finalize(aliasInsert)
                }

                let updateLabel = try prepare("""
                    UPDATE recognition_labels SET normalized_char = ? WHERE class_id = ?
                    """)
                bind(relation.normalized, to: updateLabel, at: 1)
                sqlite3_bind_int(updateLabel, 2, seed.classId)
                try stepDone(updateLabel)
                sqlite3_finalize(updateLabel)
            }

            let mark = try prepare("INSERT INTO app_meta(key, value) VALUES (?, ?)")
            bind(migrationKey, to: mark, at: 1)
            bind(String(seeds.count), to: mark, at: 2)
            try stepDone(mark)
            sqlite3_finalize(mark)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Installs the verified Commons catalog into Application Support so the app
    /// remains fully offline after first launch. Existing user-entered glyphs and
    /// characters are linked and preserved instead of being replaced.
    private func seedBundledGlyphCatalogIfNeeded() throws {
        let migrationKey = "bundled_glyph_catalog_v2"
        let check = try prepare("SELECT 1 FROM app_meta WHERE key = ? LIMIT 1")
        bind(migrationKey, to: check, at: 1)
        let alreadySeeded = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard !alreadySeeded,
              let manifestURL = Bundle.main.url(
                  forResource: "glyph_catalog",
                  withExtension: "json"
              ),
              let resourcesURL = Bundle.main.resourceURL else { return }

        let seeds = try JSONDecoder().decode(
            [BundledGlyphSeed].self,
            from: Data(contentsOf: manifestURL)
        )
        let bundledDirectory = rootDirectory.appendingPathComponent(
            "BundledGlyphs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundledDirectory,
            withIntermediateDirectories: true
        )

        // Copy before the transaction; a failed copy must never leave half-seeded rows.
        var localPaths: [String: String] = [:]
        for seed in seeds {
            let source = resourcesURL
                .appendingPathComponent("Glyphs", isDirectory: true)
                .appendingPathComponent(seed.asset)
            let target = bundledDirectory.appendingPathComponent(seed.asset)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw AppError.message("内置字形资源缺失：\(seed.asset)")
            }
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
            localPaths[seed.asset] = target.path
        }

        try execute("BEGIN IMMEDIATE")
        do {
            // Replace only the bundled catalog. User-entered glyphs have no
            // bundled_key and are deliberately preserved across this migration.
            try execute("DELETE FROM glyphs WHERE bundled_key IS NOT NULL")
            try execute("DELETE FROM catalog_characters")

            for seed in seeds {
                let relation = conservativeCharacterRelation(seed.character)
                var existingCharacterId: Int64?
                for alias in relation.aliases where existingCharacterId == nil {
                    existingCharacterId = try characterId(forAlias: alias)
                }

                if existingCharacterId == nil {
                    let insert = try prepare("""
                        INSERT OR IGNORE INTO characters(
                            normalized_char, simplified_char, traditional_char, variants, explanation
                        ) VALUES (?, ?, ?, '[]', NULL)
                        """)
                    bind(relation.normalized, to: insert, at: 1)
                    bind(relation.simplified, to: insert, at: 2)
                    bind(relation.traditional, to: insert, at: 3)
                    try stepDone(insert)
                    sqlite3_finalize(insert)
                    existingCharacterId = try characterId(forNormalized: relation.normalized)
                }
                guard let characterId = existingCharacterId,
                      let localPath = localPaths[seed.asset] else { continue }

                let updateCharacter = try prepare("""
                    UPDATE characters
                    SET simplified_char = COALESCE(simplified_char, ?),
                        traditional_char = COALESCE(traditional_char, ?)
                    WHERE id = ?
                    """)
                bind(relation.simplified, to: updateCharacter, at: 1)
                bind(relation.traditional, to: updateCharacter, at: 2)
                sqlite3_bind_int64(updateCharacter, 3, characterId)
                try stepDone(updateCharacter)
                sqlite3_finalize(updateCharacter)

                for alias in relation.aliases {
                    let aliasInsert = try prepare("""
                        INSERT OR IGNORE INTO character_aliases(alias, character_id, alias_type)
                        VALUES (?, ?, 'catalog')
                        """)
                    bind(alias, to: aliasInsert, at: 1)
                    sqlite3_bind_int64(aliasInsert, 2, characterId)
                    try stepDone(aliasInsert)
                    sqlite3_finalize(aliasInsert)
                }

                let catalogInsert = try prepare("""
                    INSERT INTO catalog_characters(character_id, rank)
                    VALUES (?, ?)
                    ON CONFLICT(character_id) DO UPDATE SET rank = MIN(rank, excluded.rank)
                    """)
                sqlite3_bind_int64(catalogInsert, 1, characterId)
                sqlite3_bind_int(catalogInsert, 2, Int32(seed.rank))
                try stepDone(catalogInsert)
                sqlite3_finalize(catalogInsert)

                let glyphInsert = try prepare("""
                    INSERT OR IGNORE INTO glyphs(
                        character_id, period, image_path, source, source_number,
                        transcription, confidence, notes, source_url, license, bundled_key
                    ) VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
                    """)
                sqlite3_bind_int64(glyphInsert, 1, characterId)
                bind(seed.period, to: glyphInsert, at: 2)
                bind(localPath, to: glyphInsert, at: 3)
                bind(seed.source, to: glyphInsert, at: 4)
                bind(seed.sourceNumber, to: glyphInsert, at: 5)
                bind(seed.transcription, to: glyphInsert, at: 6)
                bind(seed.notes, to: glyphInsert, at: 7)
                bind(seed.sourceURL, to: glyphInsert, at: 8)
                bind(seed.license, to: glyphInsert, at: 9)
                bind(seed.asset, to: glyphInsert, at: 10)
                try stepDone(glyphInsert)
                sqlite3_finalize(glyphInsert)
            }

            let mark = try prepare("INSERT INTO app_meta(key, value) VALUES (?, ?)")
            bind(migrationKey, to: mark, at: 1)
            bind(String(seeds.count), to: mark, at: 2)
            try stepDone(mark)
            sqlite3_finalize(mark)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Imports Unicode-published character relationships and sourced Chinese
    /// meanings. Direct simplified/traditional/Z variants become aliases;
    /// context-dependent semantic variants remain display-only related forms.
    private func seedCharacterMetadataIfNeeded() throws {
        let migrationKey = "character_metadata_v2"
        let check = try prepare("SELECT 1 FROM app_meta WHERE key = ? LIMIT 1")
        bind(migrationKey, to: check, at: 1)
        let alreadySeeded = sqlite3_step(check) == SQLITE_ROW
        sqlite3_finalize(check)
        guard !alreadySeeded,
              let metadataURL = Bundle.main.url(
                  forResource: "character_metadata",
                  withExtension: "json"
              ) else { return }

        let seeds = try JSONDecoder().decode(
            [CharacterMetadataSeed].self,
            from: Data(contentsOf: metadataURL)
        )
        var aggregate: [Int64: (
            direct: Set<String>,
            related: Set<String>,
            definition: String?,
            chineseDefinition: String?
        )] = [:]
        for seed in seeds {
            guard let characterId = try characterId(forAlias: seed.character)
                ?? characterId(forNormalized: seed.character) else { continue }
            var value = aggregate[characterId] ?? ([], [], nil, nil)
            value.direct.formUnion(seed.directVariants)
            value.related.formUnion(seed.relatedVariants)
            if value.definition == nil, let definition = seed.definition, !definition.isEmpty {
                value.definition = definition
            }
            if value.chineseDefinition == nil,
               let chineseDefinition = seed.chineseDefinition,
               !chineseDefinition.isEmpty {
                value.chineseDefinition = chineseDefinition
            }
            aggregate[characterId] = value
        }

        try execute("BEGIN IMMEDIATE")
        do {
            for (characterId, metadata) in aggregate {
                let current = try prepare("""
                    SELECT normalized_char, simplified_char, traditional_char,
                           variants, related_variants, explanation
                    FROM characters WHERE id = ?
                    """)
                sqlite3_bind_int64(current, 1, characterId)
                guard sqlite3_step(current) == SQLITE_ROW else {
                    sqlite3_finalize(current)
                    continue
                }
                let normalized = text(current, 0) ?? ""
                let simplified = text(current, 1)
                let traditional = text(current, 2)
                let existingDirect = decodeStringArray(text(current, 3))
                let existingRelated = decodeStringArray(text(current, 4))
                let existingExplanation = text(current, 5)
                sqlite3_finalize(current)

                let core = Set([normalized, simplified, traditional].compactMap { $0 })
                let direct = Set(existingDirect)
                    .union(metadata.direct)
                    .subtracting(core)
                    .sorted()
                let related = Set(existingRelated)
                    .union(metadata.related)
                    .subtracting(core)
                    .subtracting(Set(direct))
                    .sorted()
                let directJSON = encodeStringArray(direct)
                let relatedJSON = encodeStringArray(related)
                // v1 populated many rows with the raw English Unihan gloss.
                // Replace that generated value with sourced Chinese text, but
                // preserve any explanation that the user entered themselves.
                let generatedEnglish = metadata.definition
                let mayReplace = existingExplanation == nil
                    || existingExplanation == generatedEnglish
                let explanation = mayReplace
                    ? (metadata.chineseDefinition ?? generatedEnglish)
                    : existingExplanation

                let update = try prepare("""
                    UPDATE characters
                    SET variants = ?, related_variants = ?, explanation = ?
                    WHERE id = ?
                    """)
                bind(directJSON, to: update, at: 1)
                bind(relatedJSON, to: update, at: 2)
                bind(explanation, to: update, at: 3)
                sqlite3_bind_int64(update, 4, characterId)
                try stepDone(update)
                sqlite3_finalize(update)

                for alias in metadata.direct where !alias.isEmpty {
                    let aliasInsert = try prepare("""
                        INSERT OR IGNORE INTO character_aliases(alias, character_id, alias_type)
                        VALUES (?, ?, 'unihan')
                        """)
                    bind(alias, to: aliasInsert, at: 1)
                    sqlite3_bind_int64(aliasInsert, 2, characterId)
                    try stepDone(aliasInsert)
                    sqlite3_finalize(aliasInsert)
                }
            }

            let mark = try prepare("INSERT INTO app_meta(key, value) VALUES (?, ?)")
            bind(migrationKey, to: mark, at: 1)
            bind(String(seeds.count), to: mark, at: 2)
            try stepDone(mark)
            sqlite3_finalize(mark)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func ensureCharacterColumns() throws {
        if try !hasColumn("related_variants", in: "characters") {
            try execute(
                "ALTER TABLE characters ADD COLUMN related_variants TEXT NOT NULL DEFAULT '[]'"
            )
        }
    }

    private func ensureGlyphColumns() throws {
        let columns: [(String, String)] = [
            ("source_url", "TEXT"),
            ("license", "TEXT"),
            ("bundled_key", "TEXT")
        ]
        for (column, definition) in columns {
            if try !hasColumn(column, in: "glyphs") {
                try execute("ALTER TABLE glyphs ADD COLUMN \(column) \(definition)")
            }
        }
        try execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_glyph_bundled_key
            ON glyphs(bundled_key) WHERE bundled_key IS NOT NULL
            """)
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column { return true }
        }
        return false
    }

    private func characterId(forAlias alias: String) throws -> Int64? {
        let statement = try prepare(
            "SELECT character_id FROM character_aliases WHERE alias = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(alias, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func characterId(forNormalized character: String) throws -> Int64? {
        let statement = try prepare(
            "SELECT id FROM characters WHERE normalized_char = ? LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        bind(character, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    /// Foundation's ICU conversion is accepted only when a one-character mapping
    /// round-trips exactly. This keeps useful simplified/traditional aliases while
    /// avoiding guessed OCR class mappings.
    private func conservativeCharacterRelation(_ character: String) -> (
        normalized: String,
        simplified: String?,
        traditional: String?,
        aliases: [String]
    ) {
        let hansHant = StringTransform("Hans-Hant")
        let hantHans = StringTransform("Hant-Hans")
        let toTraditional = character.applyingTransform(hansHant, reverse: false)
        let toSimplified = character.applyingTransform(hantHans, reverse: false)

        if let traditional = toTraditional,
           traditional != character,
           isCJKCharacter(traditional),
           traditional.applyingTransform(hantHans, reverse: false) == character {
            return (traditional, character, traditional, [traditional, character])
        }
        if let simplified = toSimplified,
           simplified != character,
           isCJKCharacter(simplified),
           simplified.applyingTransform(hansHant, reverse: false) == character {
            return (character, simplified, character, [character, simplified])
        }
        return (character, nil, nil, [character])
    }

    private func isCJKCharacter(_ value: String) -> Bool {
        guard value.count == 1,
              value.unicodeScalars.count == 1,
              let scalar = value.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F,
             0x30000...0x3347F:
            return true
        default:
            return false
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? sqliteMessage
            sqlite3_free(error)
            throw AppError.message(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AppError.message(sqliteMessage)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AppError.message(sqliteMessage)
        }
    }

    private var sqliteMessage: String {
        guard let db, let value = sqlite3_errmsg(db) else { return "数据库错误" }
        return String(cString: value)
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalNormalize(_ value: String) -> String? {
        let result = normalize(value)
        return result.isEmpty ? nil : result
    }

    private func decodeStringArray(_ value: String?) -> [String] {
        guard let value else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }

    private func encodeStringArray(_ value: [String]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private let schema = """
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS characters (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        normalized_char TEXT NOT NULL UNIQUE,
        simplified_char TEXT,
        traditional_char TEXT,
        variants TEXT NOT NULL DEFAULT '[]',
        related_variants TEXT NOT NULL DEFAULT '[]',
        explanation TEXT,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
    CREATE TABLE IF NOT EXISTS character_aliases (
        alias TEXT PRIMARY KEY,
        character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
        alias_type TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS glyphs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        character_id INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
        period TEXT NOT NULL,
        image_path TEXT NOT NULL,
        source TEXT,
        source_number TEXT,
        transcription TEXT,
        confidence REAL CHECK(confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
        notes TEXT,
        source_url TEXT,
        license TEXT,
        bundled_key TEXT
    );
    CREATE TABLE IF NOT EXISTS recognition_labels (
        class_id INTEGER PRIMARY KEY,
        normalized_char TEXT,
        label_name TEXT NOT NULL UNIQUE,
        notes TEXT
    );
    CREATE TABLE IF NOT EXISTS app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS catalog_characters (
        character_id INTEGER PRIMARY KEY REFERENCES characters(id) ON DELETE CASCADE,
        rank INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_alias_character ON character_aliases(character_id);
    CREATE INDEX IF NOT EXISTS idx_glyph_character_period ON glyphs(character_id, period);
    """
}
