import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct LogEntry: Identifiable {
    let id = UUID()
    let filename: String
    let status: Status

    enum Status {
        case success
        case skipped
        case alreadyExists
        case error(String)

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .skipped, .alreadyExists: return "minus.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .skipped, .alreadyExists: return .orange
            case .error: return .red
            }
        }

        var description: String {
            switch self {
            case .success: return "Converted"
            case .skipped: return "Skipped (already DC-S5)"
            case .alreadyExists: return "Skipped (already converted)"
            case .error(let msg): return msg
            }
        }
    }
}

struct PreviewResult {
    let file: URL
    let action: Action
    let analysisResult: ContentView.AnalysisResult?

    enum Action {
        case willConvert
        case willSkipAlreadyS5
        case willSkipAlreadyConverted
        case willError(String)
    }
}

struct ContentView: View {
    @State private var selectedFolder: URL?
    @State private var isProcessing = false
    @State private var isScanning = false
    @State private var statusMessage = "Select or drop a folder containing RW2 files"
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var outputFolder: URL?
    @State private var logEntries: [LogEntry] = []
    @State private var isDragOver = false
    @State private var showConfirmation = false
    @State private var previewResults: [PreviewResult] = []

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "camera.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading) {
                    Text("S9 to S5 Converter")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Convert Lumix S9 RW2 files for Capture One compatibility")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Drop zone / folder display
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(isDragOver ? .accentColor : .secondary.opacity(0.5))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDragOver ? Color.accentColor.opacity(0.1) : Color.clear)
                    )

                if let folder = selectedFolder {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                        Text(folder.lastPathComponent)
                            .fontWeight(.medium)
                        Text(folder.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("Drop folder here")
                            .foregroundColor(.secondary)
                        Text("or use Choose Folder button")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
            .frame(height: 100)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
            }

            // Progress
            if isScanning {
                VStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Scanning files...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if isProcessing {
                VStack(spacing: 4) {
                    ProgressView(value: Double(processedCount), total: Double(max(totalCount, 1)))
                        .progressViewStyle(.linear)
                    Text("Converting: \(processedCount) / \(totalCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Status message
            Text(statusMessage)
                .font(.callout)
                .foregroundColor(statusMessage.contains("Error") ? .red : .secondary)
                .multilineTextAlignment(.center)

            // Buttons
            HStack(spacing: 12) {
                Button(action: selectFolder) {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing || isScanning)

                Button(action: scanFiles) {
                    Label("Convert Files", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolder == nil || isProcessing || isScanning)
            }

            if let output = outputFolder {
                Button(action: { NSWorkspace.shared.open(output) }) {
                    Label("Open Converted Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            // Conversion log
            if !logEntries.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Conversion Log")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.medium)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(logEntries.reversed()) { entry in
                                HStack(spacing: 8) {
                                    Image(systemName: entry.status.icon)
                                        .foregroundColor(entry.status.color)
                                        .font(.system(size: 12))
                                    Text(entry.filename)
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(entry.status.description)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(20)
        .frame(width: 450, height: logEntries.isEmpty ? 380 : 520)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showConfirmation) {
            confirmationSheet
        }
    }

    private var confirmationSheet: some View {
        let toConvert = previewResults.filter { if case .willConvert = $0.action { return true }; return false }.count
        let toSkipS5 = previewResults.filter { if case .willSkipAlreadyS5 = $0.action { return true }; return false }.count
        let toSkipConverted = previewResults.filter { if case .willSkipAlreadyConverted = $0.action { return true }; return false }.count
        let toError = previewResults.filter { if case .willError = $0.action { return true }; return false }.count

        return VStack(spacing: 16) {
            Text("Conversion Preview")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                if toConvert > 0 {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("\(toConvert) file\(toConvert == 1 ? "" : "s") will be converted")
                    }
                }
                if toSkipS5 > 0 {
                    HStack {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.orange)
                        Text("\(toSkipS5) file\(toSkipS5 == 1 ? "" : "s") already DC-S5")
                    }
                }
                if toSkipConverted > 0 {
                    HStack {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.orange)
                        Text("\(toSkipConverted) file\(toSkipConverted == 1 ? "" : "s") already converted")
                    }
                }
                if toError > 0 {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("\(toError) file\(toError == 1 ? "" : "s") with errors")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if toConvert == 0 {
                Text("Nothing to convert")
                    .foregroundColor(.secondary)
                    .italic()
            }

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    showConfirmation = false
                }
                .buttonStyle(.bordered)

                Button("Convert") {
                    showConfirmation = false
                    performConversion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(toConvert == 0)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func sendCompletionNotification(successCount: Int, skippedCount: Int, errorCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Conversion Complete"

        if errorCount > 0 {
            content.body = "Converted \(successCount) files with \(errorCount) errors"
        } else if skippedCount > 0 {
            content.body = "Converted \(successCount) files, \(skippedCount) skipped"
        } else {
            content.body = "Successfully converted \(successCount) files"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }

            DispatchQueue.main.async {
                selectedFolder = url
                outputFolder = nil
                logEntries = []
                statusMessage = "Ready to convert RW2 files"
            }
        }
        return true
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing Lumix S9 RW2 files"

        if panel.runModal() == .OK {
            selectedFolder = panel.url
            outputFolder = nil
            logEntries = []
            statusMessage = "Ready to convert RW2 files"
        }
    }

    private func scanFiles() {
        guard let folder = selectedFolder else { return }

        isScanning = true
        previewResults = []
        statusMessage = "Scanning files..."

        Task {
            do {
                let rw2Files = try findRW2Files(in: folder)

                if rw2Files.isEmpty {
                    await MainActor.run {
                        statusMessage = "No RW2 files found in the selected folder"
                        isScanning = false
                    }
                    return
                }

                let convertedFolder = folder.appendingPathComponent("Converted")
                var results: [PreviewResult] = []

                for file in rw2Files {
                    let outputURL = convertedFolder.appendingPathComponent(file.lastPathComponent)

                    if FileManager.default.fileExists(atPath: outputURL.path) {
                        results.append(PreviewResult(file: file, action: .willSkipAlreadyConverted, analysisResult: nil))
                        continue
                    }

                    let analysis = analyzeRW2File(file)
                    switch analysis {
                    case .shouldConvert:
                        results.append(PreviewResult(file: file, action: .willConvert, analysisResult: analysis))
                    case .skip:
                        results.append(PreviewResult(file: file, action: .willSkipAlreadyS5, analysisResult: nil))
                    case .error(let msg):
                        results.append(PreviewResult(file: file, action: .willError(msg), analysisResult: nil))
                    }
                }

                await MainActor.run {
                    previewResults = results
                    isScanning = false
                    statusMessage = "Ready to convert RW2 files"
                    showConfirmation = true
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isScanning = false
                }
            }
        }
    }

    private func performConversion() {
        guard let folder = selectedFolder else { return }

        isProcessing = true
        processedCount = 0
        outputFolder = nil
        logEntries = []
        totalCount = previewResults.count
        statusMessage = "Converting files..."

        Task {
            do {
                let convertedFolder = folder.appendingPathComponent("Converted")
                let fileManager = FileManager.default

                if !fileManager.fileExists(atPath: convertedFolder.path) {
                    try fileManager.createDirectory(at: convertedFolder, withIntermediateDirectories: true)
                }

                var successCount = 0
                var skippedCount = 0
                var errors: [String] = []

                for preview in previewResults {
                    let logStatus: LogEntry.Status

                    switch preview.action {
                    case .willConvert:
                        if case .shouldConvert(let modelOffset, let modelLength, _) = preview.analysisResult {
                            let result = performSingleConversion(
                                source: preview.file,
                                outputFolder: convertedFolder,
                                modelOffset: modelOffset,
                                modelLength: modelLength
                            )
                            switch result {
                            case .success:
                                successCount += 1
                                logStatus = .success
                            case .error(let message):
                                errors.append("\(preview.file.lastPathComponent): \(message)")
                                logStatus = .error(message)
                            default:
                                logStatus = .error("Unexpected result")
                            }
                        } else {
                            logStatus = .error("Invalid analysis result")
                        }
                    case .willSkipAlreadyS5:
                        skippedCount += 1
                        logStatus = .skipped
                    case .willSkipAlreadyConverted:
                        skippedCount += 1
                        logStatus = .alreadyExists
                    case .willError(let msg):
                        errors.append("\(preview.file.lastPathComponent): \(msg)")
                        logStatus = .error(msg)
                    }

                    await MainActor.run {
                        processedCount += 1
                        logEntries.append(LogEntry(filename: preview.file.lastPathComponent, status: logStatus))
                    }
                }

                await MainActor.run {
                    isProcessing = false
                    outputFolder = convertedFolder
                    if errors.isEmpty {
                        if skippedCount > 0 {
                            statusMessage = "Converted \(successCount) files, \(skippedCount) skipped"
                        } else {
                            statusMessage = "Successfully converted \(successCount) files!"
                        }
                    } else {
                        statusMessage = "Converted \(successCount)/\(totalCount) files. \(errors.count) errors."
                        errorMessage = errors.prefix(5).joined(separator: "\n")
                        if errors.count > 5 {
                            errorMessage += "\n...and \(errors.count - 5) more errors"
                        }
                        showError = true
                    }
                    sendCompletionNotification(successCount: successCount, skippedCount: skippedCount, errorCount: errors.count)
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }

    private func performSingleConversion(source fileURL: URL, outputFolder: URL, modelOffset: UInt32, modelLength: UInt32) -> ConvertResult {
        let fileManager = FileManager.default
        let outputURL = outputFolder.appendingPathComponent(fileURL.lastPathComponent)

        do {
            // Copy to output folder
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try fileManager.copyItem(at: fileURL, to: outputURL)

            // Get original file attributes
            let originalAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let originalSize = originalAttributes[.size] as? UInt64 else {
                try? fileManager.removeItem(at: outputURL)
                return .error("Could not get file size")
            }

            // Modify the copy
            let modifyResult = modifyModelTag(fileURL: outputURL, modelOffset: modelOffset, modelLength: modelLength)
            guard case .success = modifyResult else {
                try? fileManager.removeItem(at: outputURL)
                return modifyResult
            }

            // Validate
            let validationResult = validateModifiedFile(fileURL: outputURL, originalSize: originalSize, modelOffset: modelOffset)
            if case .error(let msg) = validationResult {
                try? fileManager.removeItem(at: outputURL)
                return .error("Validation failed: \(msg)")
            }

            // Verify size
            let modifiedAttributes = try fileManager.attributesOfItem(atPath: outputURL.path)
            guard let modifiedSize = modifiedAttributes[.size] as? UInt64 else {
                try? fileManager.removeItem(at: outputURL)
                return .error("Could not verify modified file size")
            }

            if modifiedSize != originalSize {
                try? fileManager.removeItem(at: outputURL)
                return .error("File size changed")
            }

            // Preserve dates
            var datesToPreserve: [FileAttributeKey: Any] = [:]
            if let creationDate = originalAttributes[.creationDate] {
                datesToPreserve[.creationDate] = creationDate
            }
            if let modificationDate = originalAttributes[.modificationDate] {
                datesToPreserve[.modificationDate] = modificationDate
            }
            if !datesToPreserve.isEmpty {
                try? fileManager.setAttributes(datesToPreserve, ofItemAtPath: outputURL.path)
            }

            return .success
        } catch {
            try? fileManager.removeItem(at: outputURL)
            return .error(error.localizedDescription)
        }
    }

    private func findRW2Files(in folder: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return contents.filter { url in
            url.pathExtension.uppercased() == "RW2"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    enum ConvertResult {
        case success
        case skipped
        case alreadyExists
        case error(String)
    }

    enum AnalysisResult {
        case shouldConvert(modelOffset: UInt32, modelLength: UInt32, isLittleEndian: Bool)
        case skip
        case error(String)
    }

    private func analyzeRW2File(_ fileURL: URL) -> AnalysisResult {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }

            guard let headerData = try fileHandle.read(upToCount: 8) else {
                return .error("Could not read file header")
            }

            let isLittleEndian: Bool
            if headerData[0] == 0x49 && headerData[1] == 0x49 {
                isLittleEndian = true
            } else if headerData[0] == 0x4D && headerData[1] == 0x4D {
                isLittleEndian = false
            } else {
                return .error("Not a valid TIFF/RW2 file")
            }

            let magic = readUInt16(from: headerData, at: 2, littleEndian: isLittleEndian)
            if magic != 85 && magic != 42 {
                return .error("Not a valid RW2 file (magic: \(magic))")
            }

            let ifd0Offset = readUInt32(from: headerData, at: 4, littleEndian: isLittleEndian)

            try fileHandle.seek(toOffset: UInt64(ifd0Offset))
            guard let ifdCountData = try fileHandle.read(upToCount: 2) else {
                return .error("Could not read IFD")
            }

            let entryCount = readUInt16(from: ifdCountData, at: 0, littleEndian: isLittleEndian)

            guard let ifdData = try fileHandle.read(upToCount: Int(entryCount) * 12) else {
                return .error("Could not read IFD entries")
            }

            let modelTag: UInt16 = 0x0110

            for i in 0..<Int(entryCount) {
                let entryOffset = i * 12
                let tag = readUInt16(from: ifdData, at: entryOffset, littleEndian: isLittleEndian)

                if tag == modelTag {
                    let type = readUInt16(from: ifdData, at: entryOffset + 2, littleEndian: isLittleEndian)
                    let count = readUInt32(from: ifdData, at: entryOffset + 4, littleEndian: isLittleEndian)

                    guard type == 2 else {
                        return .error("Model tag has unexpected type: \(type)")
                    }

                    let stringOffset: UInt32
                    if count <= 4 {
                        stringOffset = UInt32(ifd0Offset) + 2 + UInt32(entryOffset) + 8
                    } else {
                        stringOffset = readUInt32(from: ifdData, at: entryOffset + 8, littleEndian: isLittleEndian)
                    }

                    try fileHandle.seek(toOffset: UInt64(stringOffset))
                    guard let modelData = try fileHandle.read(upToCount: Int(count)) else {
                        return .error("Could not read model string")
                    }

                    let currentModel = String(data: modelData.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""

                    if currentModel == "DC-S5" {
                        return .skip
                    }

                    if !currentModel.contains("S9") {
                        return .error("Not a Lumix S9 file (Model: \(currentModel))")
                    }

                    let newModel = "DC-S5"
                    if newModel.count + 1 > Int(count) {
                        return .error("New model name too long for field")
                    }

                    return .shouldConvert(modelOffset: stringOffset, modelLength: count, isLittleEndian: isLittleEndian)
                }
            }

            return .error("Model tag not found in file")

        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func modifyModelTag(fileURL: URL, modelOffset: UInt32, modelLength: UInt32) -> ConvertResult {
        do {
            let fileHandle = try FileHandle(forUpdating: fileURL)
            defer { try? fileHandle.close() }

            let newModel = "DC-S5"
            var newModelBytes = Array(newModel.utf8)
            newModelBytes.append(0)

            while newModelBytes.count < Int(modelLength) {
                newModelBytes.append(0)
            }

            try fileHandle.seek(toOffset: UInt64(modelOffset))
            try fileHandle.write(contentsOf: Data(newModelBytes))

            return .success
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func validateModifiedFile(fileURL: URL, originalSize: UInt64, modelOffset: UInt32) -> ConvertResult {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? fileHandle.close() }

            guard let headerData = try fileHandle.read(upToCount: 8) else {
                return .error("Could not read modified file header")
            }

            let isLittleEndian: Bool
            if headerData[0] == 0x49 && headerData[1] == 0x49 {
                isLittleEndian = true
            } else if headerData[0] == 0x4D && headerData[1] == 0x4D {
                isLittleEndian = false
            } else {
                return .error("Modified file has invalid TIFF header")
            }

            let magic = readUInt16(from: headerData, at: 2, littleEndian: isLittleEndian)
            if magic != 85 && magic != 42 {
                return .error("Modified file has invalid magic number")
            }

            try fileHandle.seek(toOffset: UInt64(modelOffset))
            guard let modelData = try fileHandle.read(upToCount: 5) else {
                return .error("Could not read modified model string")
            }

            let writtenModel = String(data: modelData, encoding: .ascii) ?? ""
            if writtenModel != "DC-S5" {
                return .error("Model not written correctly: got '\(writtenModel)'")
            }

            return .success
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Binary Reading Helpers

    private func readUInt16(from data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        if littleEndian {
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
    }

    private func readUInt32(from data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        if littleEndian {
            return UInt32(data[offset]) |
                   (UInt32(data[offset + 1]) << 8) |
                   (UInt32(data[offset + 2]) << 16) |
                   (UInt32(data[offset + 3]) << 24)
        } else {
            return (UInt32(data[offset]) << 24) |
                   (UInt32(data[offset + 1]) << 16) |
                   (UInt32(data[offset + 2]) << 8) |
                   UInt32(data[offset + 3])
        }
    }
}

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }
}

#Preview {
    ContentView()
}
