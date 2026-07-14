import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var showingEntry = false
    @State private var showingOnboarding = false
    @State private var expandedMeaningCharacterID: Int64?
    @AppStorage("hasSeenOnboardingV4") private var hasSeenOnboarding = false
    @AppStorage("usesTraditionalInterfaceV2") private var usesTraditionalInterface = true

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            VStack(spacing: 18) {
                topBar
                Group {
                    switch model.section {
                    case .lookup: lookupView
                    case .catalog: catalogView
                    case .recognition: recognitionView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(22)
        }
        .foregroundStyle(AppPalette.ink)
        .frame(minWidth: 920, minHeight: 620)
        .onAppear {
            if !hasSeenOnboarding {
                showingOnboarding = true
                hasSeenOnboarding = true
            }
        }
        .sheet(isPresented: $showingEntry) {
            EntrySheet(
                model: model,
                character: model.character,
                usesTraditional: usesTraditionalInterface
            )
        }
        .sheet(isPresented: $showingOnboarding) {
            tutorialSheet
        }
        .alert(
            ui("提示", "提示"),
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button(ui("好", "好")) { model.alertMessage = nil }
        } message: {
            Text(AppDisplay.content(model.alertMessage ?? "", usesTraditional: usesTraditionalInterface))
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            AdaptiveIconButton(
                symbol: "chevron.left",
                help: ui("返回上一页", "返回上一頁")
            ) { model.goBack() }
                .disabled(!model.canGoBack)
                .opacity(model.canGoBack ? 1 : 0.38)
            AdaptiveIconButton(
                symbol: "square.grid.2x2",
                help: ui("已收录字库", "已收錄字庫"),
                selected: model.section == .catalog
            ) { model.showCatalog() }
            AdaptiveIconButton(
                symbol: "viewfinder",
                help: ui("识别", "識別"),
                selected: model.section == .recognition
            ) { model.showRecognition() }

            if model.section != .recognition {
                HStack(spacing: 8) {
                    TextField(
                        model.section == .catalog
                            ? ui("筛选已收录字", "篩選已收錄字")
                            : ui("输入现代汉字", "輸入現代漢字"),
                        text: Binding(
                            get: { model.query },
                            set: model.updateQuery
                        )
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .onSubmit(model.submitSearch)
                    if !model.query.isEmpty {
                        Button { model.updateQuery("") } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppPalette.secondary.opacity(0.65))
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .interactiveButton(cornerRadius: 14)
                    }
                    Button(action: model.submitSearch) {
                        Image(systemName: "arrow.right")
                            .frame(width: 28, height: 28)
                    }
                    .interactiveButton(cornerRadius: 14)
                }
                .padding(.leading, 16)
                .padding(.trailing, 7)
                .padding(.vertical, 7)
                .frame(width: 310)
                .adaptiveGlass(cornerRadius: 22)
            }

            Spacer()

            Button {
                showingOnboarding = true
            } label: {
                Label(ui("开始使用教程", "開始使用教學"), systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 15)
                    .frame(height: 42)
            }
            .interactiveButton(cornerRadius: 21)
            .adaptiveGlass(cornerRadius: 21)

            Spacer()

            AdaptiveIconButton(symbol: "plus", help: ui("录入", "錄入")) {
                showingEntry = true
            }
            Button {
                usesTraditionalInterface.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(usesTraditionalInterface ? "繁" : "简")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .frame(width: 54, height: 42)
            }
            .interactiveButton(cornerRadius: 21)
            .adaptiveGlass(cornerRadius: 21)
            .help(ui("切换为繁体界面", "切換為簡體介面"))
        }
        .frame(height: 46)
    }

    private func ui(_ simplified: String, _ traditional: String) -> String {
        AppDisplay.localized(
            simplified: simplified,
            traditional: traditional,
            usesTraditional: usesTraditionalInterface
        )
    }

    @ViewBuilder
    private var lookupView: some View {
        if let character = model.character {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    characterHeader(character)
                    if model.visibleGlyphs.isEmpty {
                        emptyGlyphs
                    } else {
                        periodPicker
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 190), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(model.visibleGlyphs) { glyph in
                                GlyphCard(glyph: glyph, usesTraditional: usesTraditionalInterface)
                            }
                        }
                    }
                }
                .padding(2)
            }
            // 释义随详情页整体滚动，不额外显示滚动条，避免视觉干扰。
            .scrollIndicators(.hidden)
        } else if !model.query.isEmpty, !model.filteredCatalog.isEmpty {
            searchMatchesView
        } else if model.hasSearched {
            VStack(spacing: 14) {
                Text(ui("未找到字形资料", "未找到字形資料"))
                    .font(.callout)
                    .foregroundStyle(AppPalette.secondary)
                AdaptiveActionButton(action: model.showCatalog) {
                    Label(ui("查看已收录字库", "查看已收錄字庫"), systemImage: "square.grid.2x2")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            homeView
        }
    }

    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("常用字形")
                        .font(.headline)
                    Text("\(model.catalogCharacters.count) 字 · \(model.catalogCharacters.reduce(0) { $0 + $1.glyphCount }) \(ui("图", "圖"))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppPalette.secondary)
                    Spacer()
                    Button { model.showCatalog() } label: {
                        Text("全部")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                        .interactiveButton(cornerRadius: 14)
                        .foregroundStyle(AppPalette.secondary)
                }
                catalogGrid(Array(model.featuredCatalog.prefix(showingOnboarding ? 6 : 12)))
                if showingOnboarding {
                    firstLaunchGuide
                }
            }
            .padding(2)
        }
        .scrollIndicators(.visible)
    }

    private var searchMatchesView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(ui("匹配", "符合")) \(model.filteredCatalog.count) 字")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppPalette.secondary)
                catalogGrid(Array(model.filteredCatalog.prefix(30)))
            }
            .padding(2)
        }
        .scrollIndicators(.visible)
    }

    private var catalogView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(ui("已收录", "已收錄"))
                        .font(.title3.weight(.semibold))
                    Text("\(model.filteredCatalog.count) 字")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppPalette.secondary)
                    Spacer()
                    periodLegend
                }
                catalogGrid(model.filteredCatalog)
            }
            .padding(2)
        }
        // 字量较大，目录页保留右侧滚动条，便于快速判断和移动位置。
        .scrollIndicators(.visible)
        // 指示器留在窗口最右侧，内容向左留出安全距离，避免盖住末列卡片。
        .contentMargins(.trailing, 16, for: .scrollContent)
    }

    private func catalogGrid(_ characters: [CharacterSummary]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
            spacing: 14
        ) {
            ForEach(characters) { summary in
                CatalogTile(summary: summary, usesTraditional: usesTraditionalInterface) {
                    model.openCharacter(summary)
                }
            }
        }
    }

    private var periodLegend: some View {
        HStack(spacing: 10) {
            ForEach(["甲骨文", "金文", "战国", "小篆"], id: \.self) { period in
                Text(AppDisplay.content(period, usesTraditional: usesTraditionalInterface))
                    .font(.caption2)
                    .foregroundStyle(AppPalette.secondary)
            }
        }
    }

    private func characterHeader(_ character: CharacterRecord) -> some View {
        let displayCharacter = usesTraditionalInterface
            ? character.normalizedChar
            : (character.simplifiedChar ?? character.normalizedChar)
        return HStack(alignment: .top, spacing: 22) {
            Text(displayCharacter)
                .font(.system(size: 78, weight: .regular, design: .serif))
                .frame(width: 112, height: 132)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    compactMeta(ui("简", "簡"), character.simplifiedChar, excluding: displayCharacter)
                    compactMeta("繁", character.traditionalChar, excluding: displayCharacter)
                    compactMeta(
                        ui("异", "異"),
                        character.variants.joined(separator: " · "),
                        excluding: displayCharacter
                    )
                    compactMeta(
                        ui("相关", "相關"),
                        character.relatedVariants.joined(separator: " · "),
                        excluding: displayCharacter
                    )
                }
                if let explanation = character.explanation, !explanation.isEmpty {
                    let isExpanded = expandedMeaningCharacterID == character.id
                    Text(
                        inlineMeaning(
                            explanation,
                            characterID: character.id,
                            isExpanded: isExpanded
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(AppPalette.secondary)
                    .tint(AppPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "ancientocr", url.host == "meaning" else {
                            return .systemAction
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedMeaningCharacterID = isExpanded ? nil : character.id
                        }
                        return .handled
                    })
                }
                eraOverview(character)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(20)
        .adaptiveGlass(cornerRadius: 26)
    }

    private func eraOverview(_ character: CharacterRecord) -> some View {
        HStack(spacing: 8) {
            ForEach(character.glyphs) { glyph in
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppDisplay.period(glyph.period, usesTraditional: usesTraditionalInterface))
                        .font(.caption.weight(.semibold))
                    Text("\(ui("释读", "釋讀")) \(glyph.transcription ?? character.normalizedChar)")
                        .font(.caption2)
                    if let explanation = character.explanation, !explanation.isEmpty {
                        Text("\(ui("字义", "字義")) \(AppDisplay.content(definitionSummary(explanation), usesTraditional: usesTraditionalInterface))")
                            .font(.caption2)
                            .foregroundStyle(AppPalette.secondary)
                            .lineLimit(2)
                    }
                    if let notes = glyph.notes, !notes.isEmpty {
                        Text(AppDisplay.content(notes, usesTraditional: usesTraditionalInterface))
                            .font(.caption2)
                            .foregroundStyle(AppPalette.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// The full sourced meaning stays above; era cards use its first sense so
    /// four-period entries remain readable without hiding the glyph gallery.
    private func definitionSummary(_ value: String) -> String {
        let firstSense = value.split(separator: "；", maxSplits: 1).first.map(String.init) ?? value
        return String(firstSense.prefix(110))
    }

    private func hasExpandableMeaning(_ value: String) -> Bool {
        value.count > 90 || value.filter { $0 == "\n" }.count > 2
    }

    /// SwiftUI cannot place a separate Button inside a wrapped Text line. A
    /// custom in-app link keeps the bold action immediately after the explicit
    /// ellipsis while still behaving like a normal click target.
    private func inlineMeaning(
        _ value: String,
        characterID: Int64,
        isExpanded: Bool
    ) -> AttributedString {
        let displayValue = AppDisplay.content(value, usesTraditional: usesTraditionalInterface)
        guard hasExpandableMeaning(displayValue) else {
            return AttributedString("\(ui("释义", "釋義")) · \(displayValue)")
        }
        let flattened = displayValue.replacingOccurrences(of: "\n", with: " ")
        let visible = isExpanded
            ? displayValue
            : String(flattened.prefix(150)).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = AttributedString("\(ui("释义", "釋義")) · \(visible)\(isExpanded ? " " : "… ")")
        let label = isExpanded ? ui("收起", "收起") : ui("展开", "展開")
        if let action = try? AttributedString(
            markdown: "[**\(label)**](ancientocr://meaning/\(characterID))"
        ) {
            result.append(action)
        } else {
            result.append(AttributedString(label))
        }
        return result
    }

    @ViewBuilder
    private func compactMeta(_ label: String, _ value: String?, excluding: String) -> some View {
        if let value, !value.isEmpty, value != excluding {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(AppPalette.secondary.opacity(0.8))
                Text(value)
                    .font(.system(size: 15, design: .serif))
                    .lineLimit(2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.38), in: Capsule())
        }
    }

    private var firstLaunchGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(ui("开始使用", "開始使用"))
                    .font(.headline)
                Spacer()
                Button {
                    showingOnboarding = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
                .interactiveButton(cornerRadius: 12)
            }
            HStack(alignment: .top, spacing: 14) {
                guideStep("1", ui("查询", "查詢"), ui("输入简体、繁体或异体字，按 Return 查看字条", "輸入簡體、繁體或異體字，按 Return 查看字條"))
                guideStep("2", ui("字库", "字庫"), ui("点左侧方格浏览全部有图字条，可实时筛选", "點左側方格瀏覽全部有圖字條，可即時篩選"))
                guideStep("3", ui("识别", "識別"), ui("选择古文字图片，查看前五候选与置信度", "選擇古文字圖片，查看前五候選與置信度"))
                guideStep("4", ui("录入", "錄入"), ui("用右上角加号补充字形、时代、来源与编号", "用右上角加號補充字形、時代、來源與編號"))
            }
        }
        .padding(20)
        .adaptiveGlass(cornerRadius: 24)
    }

    /// 首次開啟自動顯示，也可由工具列中央按鈕隨時重新查看。
    private var tutorialSheet: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(ui("开始使用教程", "開始使用教學"))
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button { showingOnboarding = false } label: {
                        Text(ui("完成", "完成"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Capsule())
                    }
                        .interactiveButton(cornerRadius: 16)
                        .font(.subheadline.weight(.semibold))
                }

                VStack(alignment: .leading, spacing: 16) {
                    guideStep("1", ui("浏览全部文字", "瀏覽全部文字"), ui("打开后即进入完整字库。拖动右侧滚动条，或在左上方输入文字筛选。", "開啟後即進入完整字庫。拖動右側捲動條，或在左上方輸入文字篩選。"))
                    guideStep("2", ui("查询与分期", "查詢與分期"), ui("在搜索框输入简体、繁体或异体字，再按 Return；结果按四个时代分类，左上返回箭头可回到上一页。", "在搜尋框輸入簡體、繁體或異體字，再按 Return；結果按四個時代分類，左上返回箭頭可回到上一頁。"))
                    guideStep("3", ui("查看释义", "查看釋義"), ui("字头显示简体、繁体、异体、来源、释读与字义；较长内容可点省略号后的“展开”，再点“收起”。", "字頭顯示簡體、繁體、異體、來源、釋讀與字義；較長內容可點省略號後的「展開」，再點「收起」。"))
                    guideStep("4", ui("图片识别", "圖片識別"), ui("点取景框并选择图片，系统列出前五个候选及置信度；不确定结果不会当作定论。", "點取景框並選擇圖片，系統列出前五個候選及置信度；不確定結果不會當作定論。"))
                    guideStep("5", ui("补充资料", "補充資料"), ui("点右上角加号，录入文字、时代、图片、来源、编号及备注。", "點右上角加號，錄入文字、時代、圖片、來源、編號及備註。"))
                    guideStep("6", ui("简繁切换", "簡繁切換"), ui("点右上角“简／繁”按钮切换界面；每个字条始终保留简体与繁体字段，二者都能搜索。", "點右上角「簡／繁」按鈕切換介面；每個字條始終保留簡體與繁體欄位，兩者都能搜尋。"))
                }
                .padding(20)
                .adaptiveGlass(cornerRadius: 24)
            }
            .padding(26)
        }
        .foregroundStyle(AppPalette.ink)
        .frame(width: 720, height: 570)
    }

    private func guideStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 23, height: 23)
                .background(Color.white.opacity(0.62), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var periodPicker: some View {
        HStack(spacing: 8) {
            ForEach(model.periods, id: \.self) { period in
                Button { model.selectedPeriod = period } label: {
                    Text(AppDisplay.period(period, usesTraditional: usesTraditionalInterface))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                        .background(
                            model.selectedPeriod == period
                                ? Color.white.opacity(0.72)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .interactiveButton(cornerRadius: 18)
            }
            Spacer()
        }
        .padding(7)
        .adaptiveGlass(cornerRadius: 22)
    }

    private var emptyGlyphs: some View {
        VStack(spacing: 14) {
            Text(ui("尚无字形资料", "尚無字形資料"))
                .font(.callout)
                .foregroundStyle(AppPalette.secondary)
            AdaptiveActionButton(action: { showingEntry = true }) {
                Label(ui("添加字形", "新增字形"), systemImage: "plus")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .adaptiveGlass(cornerRadius: 26)
    }

    private var recognitionView: some View {
        HStack(spacing: 16) {
            VStack(spacing: 14) {
                if let image = model.recognitionImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(18)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(AppPalette.secondary.opacity(0.55))
                }
                HStack(spacing: 10) {
                    AdaptiveActionButton(action: model.chooseRecognitionImage) {
                        Label(ui("选择图片", "選擇圖片"), systemImage: "photo")
                    }
                    AdaptiveActionButton(
                        prominent: true,
                        action: model.recognize
                    ) {
                        if model.isRecognizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(ui("识别", "識別"), systemImage: "viewfinder")
                        }
                    }
                    .disabled(model.recognitionImageURL == nil || model.isRecognizing)
                }
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .adaptiveGlass(cornerRadius: 28)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(ui("候选", "候選"))
                        .font(.headline)
                    Spacer()
                    Image(systemName: "info.circle")
                        .foregroundStyle(AppPalette.secondary)
                        .help(ui("模型候选，置信度未经校准，并非确定释读", "模型候選，置信度未經校準，並非確定釋讀"))
                }
                .padding(.bottom, 12)

                if model.resolvedCandidates.isEmpty {
                    Spacer()
                    Image(systemName: "ellipsis")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(AppPalette.secondary.opacity(0.45))
                    Spacer()
                } else {
                    ForEach(model.resolvedCandidates) { candidate in
                        CandidateRow(candidate: candidate) {
                            model.openCandidate(candidate)
                        }
                    }
                    Spacer()
                    Text(AppDisplay.content(
                        model.recognition?.confidenceNotice ?? ui("模型候选 · 置信度未经校准", "模型候選 · 置信度未經校準"),
                        usesTraditional: usesTraditionalInterface
                    ))
                        .font(.caption2)
                        .foregroundStyle(AppPalette.secondary)
                    if let device = model.recognition?.device {
                        Text(device.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppPalette.secondary.opacity(0.65))
                    }
                }
            }
            .padding(20)
            .frame(width: 360)
            .frame(maxHeight: .infinity)
            .adaptiveGlass(cornerRadius: 28)
        }
    }
}

private struct CatalogTile: View {
    let summary: CharacterSummary
    let usesTraditional: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.48))
                    if let image = NSImage(contentsOfFile: summary.previewImagePath) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(12)
                    }
                    Text(usesTraditional
                        ? summary.normalizedChar
                        : (summary.simplifiedChar ?? summary.normalizedChar))
                        .font(.system(size: 20, design: .serif))
                        .padding(8)
                }
                .frame(height: 112)

                HStack {
                    HStack(spacing: 5) {
                        ForEach(summary.periods, id: \.self) { period in
                            Text(shortPeriod(period))
                                .font(.caption2)
                                .foregroundStyle(AppPalette.secondary)
                        }
                    }
                    Spacer()
                    Text("\(summary.glyphCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppPalette.secondary)
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .interactiveButton(cornerRadius: 20)
        .adaptiveGlass(cornerRadius: 20)
    }

    private func shortPeriod(_ period: String) -> String {
        switch period {
        case "甲骨文": "甲"
        case "金文": "金"
        case "战国文字": usesTraditional ? "戰" : "战"
        case "小篆": "篆"
        default: String(period.prefix(1))
        }
    }
}

private struct GlyphCard: View {
    let glyph: GlyphRecord
    let usesTraditional: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = NSImage(contentsOfFile: glyph.imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 210)
                    .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Image(systemName: "photo")
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .foregroundStyle(AppPalette.secondary.opacity(0.45))
            }
            HStack {
                Text(AppDisplay.period(glyph.period, usesTraditional: usesTraditional))
                    .font(.headline)
                Spacer()
                if let transcription = glyph.transcription, !transcription.isEmpty {
                    Text(transcription)
                        .font(.system(size: 20, design: .serif))
                }
            }
            if let source = glyph.source, !source.isEmpty {
                if let value = glyph.sourceURL, let url = URL(string: value) {
                    Link(destination: url) {
                        Label(
                            [source, glyph.sourceNumber].compactMap { $0 }.joined(separator: " · "),
                            systemImage: "arrow.up.right"
                        )
                        .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondary)
                } else {
                    Text([source, glyph.sourceNumber].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(AppPalette.secondary)
                        .lineLimit(1)
                }
            }
            if let notes = glyph.notes, !notes.isEmpty {
                Text(AppDisplay.content(notes, usesTraditional: usesTraditional))
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .adaptiveGlass(cornerRadius: 22)
    }
}

private struct CandidateRow: View {
    let candidate: ResolvedCandidate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(candidate.candidate.labelName)
                    .font(.system(size: 30, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 72, alignment: .leading)
                Spacer()
                Text(candidate.candidate.confidence, format: .percent.precision(.fractionLength(1)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(AppPalette.secondary)
                if candidate.characterId != nil {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .interactiveButton(cornerRadius: 12)
        .disabled(candidate.characterId == nil)
        Divider().opacity(0.45)
    }
}
