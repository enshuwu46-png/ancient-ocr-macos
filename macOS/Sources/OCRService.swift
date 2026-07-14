import Foundation

enum OCRService {
    static func recognize(imageURL: URL) async throws -> OCRResponse {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSynchronously(imageURL: imageURL)
        }.value
    }

    private static func recognizeSynchronously(imageURL: URL) throws -> OCRResponse {
        guard let resources = Bundle.main.resourceURL else {
            throw AppError.message("资源目录不可用")
        }
        let runner = resources
            .appendingPathComponent("ocr_runtime", isDirectory: true)
            .appendingPathComponent("ocr_runner")
        let models = resources.appendingPathComponent("Models", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: runner.path) else {
            throw AppError.message("OCR 运行组件缺失")
        }

        let process = Process()
        process.executableURL = runner
        process.arguments = [
            "--detector", models.appendingPathComponent("detector_best.pt").path,
            "--recognizer", models.appendingPathComponent("recognizer_best.pt").path,
            "--image", imageURL.path,
            "--top-k", "5"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["MPLCONFIGDIR"] = FileManager.default.temporaryDirectory.path
        environment["YOLO_CONFIG_DIR"] = FileManager.default.temporaryDirectory.path
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(message?.isEmpty == false ? message! : "识别失败")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(OCRResponse.self, from: outputData)
        } catch {
            // Ultralytics may print a one-time settings notice before the JSON
            // payload on a fresh Mac. The runner always emits JSON last.
            let lastLine = String(data: outputData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .last
                .map(String.init)
            guard let lastLine,
                  let data = lastLine.data(using: .utf8),
                  let response = try? decoder.decode(OCRResponse.self, from: data) else {
                throw AppError.message("识别结果无法解析")
            }
            return response
        }
    }
}
