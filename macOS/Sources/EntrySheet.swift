import AppKit
import SwiftUI

struct EntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var draft: EntryDraft
    @State private var error: String?
    let usesTraditional: Bool

    private let periods = ["甲骨文", "金文", "战国文字", "小篆", "其他"]

    init(
        model: AppModel,
        character: CharacterRecord? = nil,
        usesTraditional: Bool = true
    ) {
        self.model = model
        self.usesTraditional = usesTraditional
        _draft = State(initialValue: EntryDraft(character: character))
    }

    var body: some View {
        ZStack {
            AppPalette.background.ignoresSafeArea()
            VStack(spacing: 18) {
                if draft.characterId == nil {
                    HStack {
                        TextField(ui("规范字", "規範字"), text: $draft.normalizedChar)
                        TextField(ui("简体", "簡體"), text: $draft.simplifiedChar)
                        TextField(ui("繁体", "繁體"), text: $draft.traditionalChar)
                    }
                    .textFieldStyle(.roundedBorder)

                    TextField(ui("异体字，以逗号分隔", "異體字，以逗號分隔"), text: $draft.variants)
                        .textFieldStyle(.roundedBorder)
                    TextField(ui("说明", "說明"), text: $draft.explanation)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 12) {
                        Text(draft.normalizedChar)
                            .font(.system(size: 34, design: .serif))
                        Text(ui("添加字形", "新增字形"))
                            .font(.headline)
                        Spacer()
                    }
                }

                Divider().opacity(0.45)

                HStack {
                    Picker(ui("时代", "時代"), selection: $draft.period) {
                        ForEach(periods, id: \.self) {
                            Text(AppDisplay.period($0, usesTraditional: usesTraditional))
                        }
                    }
                    AdaptiveActionButton(action: chooseImage) {
                        Label(
                            draft.imageURL?.lastPathComponent ?? ui("选择字形", "選擇字形"),
                            systemImage: "photo"
                        )
                        .lineLimit(1)
                    }
                    Spacer()
                }
                HStack {
                    TextField(ui("来源", "來源"), text: $draft.source)
                    TextField(ui("编号", "編號"), text: $draft.sourceNumber)
                    TextField(ui("释读", "釋讀"), text: $draft.transcription)
                    TextField("置信度 0–1", text: $draft.confidence)
                }
                .textFieldStyle(.roundedBorder)
                TextField(ui("备注", "備註"), text: $draft.notes)
                    .textFieldStyle(.roundedBorder)

                if let error {
                    Text(AppDisplay.content(error, usesTraditional: usesTraditional))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    AdaptiveActionButton(action: { dismiss() }) {
                        Text("取消")
                    }
                    AdaptiveActionButton(prominent: true, action: save) {
                        Text(ui("保存", "儲存"))
                    }
                }
            }
            .padding(26)
            .adaptiveGlass(cornerRadius: 28)
            .padding(22)
        }
        .frame(width: 650, height: 460)
    }

    private func ui(_ simplified: String, _ traditional: String) -> String {
        AppDisplay.localized(
            simplified: simplified,
            traditional: traditional,
            usesTraditional: usesTraditional
        )
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            draft.imageURL = panel.url
        }
    }

    private func save() {
        do {
            try model.saveEntry(draft)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
