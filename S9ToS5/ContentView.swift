import SwiftUI

struct ContentView: View {
    @State private var selectedFolder: URL?
    @State private var isProcessing = false
    @State private var statusMessage = "Select a folder containing RW2 files"
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var outputFolder: URL?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("S9 to S5 Converter")
                .font(.title)
                .fontWeight(.bold)

            Text("Convert Lumix S9 RW2 files for Capture One compatibility")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            if let folder = selectedFolder {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.accentColor)
                    Text(folder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal)
            }

            if isProcessing {
                ProgressView(value: Double(processedCount), total: Double(max(totalCount, 1)))
                    .progressViewStyle(.linear)
                    .padding(.horizontal)

                Text("Processing: \(processedCount) / \(totalCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(statusMessage)
                .font(.callout)
                .foregroundColor(statusMessage.contains("Error") ? .red : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button(action: selectFolder) {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing)

                Button(action: processFiles) {
                    Label("Convert Files", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolder == nil || isProcessing)
            }

            if let output = outputFolder {
                Button(action: { NSWorkspace.shared.open(output) }) {
                    Label("Open Converted Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(30)
        .frame(width: 400, height: 380)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
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
            statusMessage = "Ready to convert RW2 files"
        }
    }

    private func processFiles() {
        guard let folder = selectedFolder else { return }

        isProcessing = true
        processedCount = 0
        outputFolder = nil
        statusMessage = "Scanning for RW2 files..."

        Task {
            do {
                let rw2Files = try findRW2Files(in: folder)

                if rw2Files.isEmpty {
                    await MainActor.run {
                        statusMessage = "No RW2 files found in the selected folder"
                        isProcessing = false
                    }
                    return
                }

                // Create Converted subfolder
                let convertedFolder = folder.appendingPathComponent("Converted")
                let fileManager = FileManager.default

                if !fileManager.fileExists(atPath: convertedFolder.path) {
                    try fileManager.createDirectory(at: convertedFolder, withIntermediateDirectories: true)
                }

                await MainActor.run {
                    totalCount = rw2Files.count
                    statusMessage = "Converting \(totalCount) files..."
                }

                var successCount = 0
                var skippedCount = 0
                var errors: [String] = []

                for file in rw2Files {
                    let result = convertRW2File(source: file, outputFolder: convertedFolder)
                    await MainActor.run {
                        processedCount += 1
                    }

                    switch result {
                    case .success:
                        successCount += 1
                    case .skipped:
                        skippedCount += 1
                    case .error(let message):
                        errors.append("\(file.lastPathComponent): \(message)")
                    }
                }

                await MainActor.run {
                    isProcessing = false
                    outputFolder = convertedFolder
                    if errors.isEmpty {
                        if skippedCount > 0 {
                            statusMessage = "Converted \(successCount) files to Converted folder, \(skippedCount) skipped"
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
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Error: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
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
        }
    }

    enum ConvertResult {
        case success
        case skipped
        case error(String)
    }

    // MARK: - Conversion (copies to output folder)

    private func convertRW2File(source fileURL: URL, outputFolder: URL) -> ConvertResult {
        let fileManager = FileManager.default
        let outputURL = outputFolder.appendingPathComponent(fileURL.lastPathComponent)

        do {
            // Step 1: Analyze source file (read-only)
            let analysisResult = analyzeRW2File(fileURL)
            switch analysisResult {
            case .shouldConvert(let modelOffset, let modelLength, _):
                // Step 2: Copy to output folder
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                try fileManager.copyItem(at: fileURL, to: outputURL)

                // Step 3: Get file size for validation
                let originalAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                guard let originalSize = originalAttributes[.size] as? UInt64 else {
                    try? fileManager.removeItem(at: outputURL)
                    return .error("Could not get file size")
                }

                // Step 4: Modify the copy
                let modifyResult = modifyModelTag(
                    fileURL: outputURL,
                    modelOffset: modelOffset,
                    modelLength: modelLength
                )

                guard case .success = modifyResult else {
                    try? fileManager.removeItem(at: outputURL)
                    return modifyResult
                }

                // Step 5: Validate the modified file
                let validationResult = validateModifiedFile(
                    fileURL: outputURL,
                    originalSize: originalSize,
                    modelOffset: modelOffset
                )

                if case .error(let msg) = validationResult {
                    try? fileManager.removeItem(at: outputURL)
                    return .error("Validation failed: \(msg)")
                }

                // Step 6: Verify file size unchanged
                let modifiedAttributes = try fileManager.attributesOfItem(atPath: outputURL.path)
                guard let modifiedSize = modifiedAttributes[.size] as? UInt64 else {
                    try? fileManager.removeItem(at: outputURL)
                    return .error("Could not verify modified file size")
                }

                if modifiedSize != originalSize {
                    try? fileManager.removeItem(at: outputURL)
                    return .error("File size changed from \(originalSize) to \(modifiedSize)")
                }

                return .success

            case .skip:
                return .skipped

            case .error(let msg):
                return .error(msg)
            }

        } catch {
            try? fileManager.removeItem(at: outputURL)
            return .error(error.localizedDescription)
        }
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

            // Parse TIFF header
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

                    // Verify new model will fit
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

            // Verify header is still valid
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

            // Verify model was written correctly
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

#Preview {
    ContentView()
}
