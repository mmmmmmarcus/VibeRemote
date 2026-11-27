import Foundation
import Darwin

// Builder-only executable: production locking/read/validation/atomic rename,
// with a macOS adapter for iOS-only protection calls; no real App Group access.
// Each worker is a fresh process. This does not verify device Data Protection.
enum VoiceIPC { static var root: URL? { nil } }

@main enum SnippetConcurrencyCheck {
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4 {
            let store = SnippetStore(directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
            do {
                try store.save(abbreviation: arguments[3], content: "synthetic concurrency fixture")
            } catch SnippetError.duplicate {
                exit(10)
            } catch {
                exit(20) // Never print record contents or arbitrary error payloads.
            }
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: arguments[0])
        let store = SnippetStore(directory: directory)
        var processes: [Process] = []
        for index in 0..<32 {
            let process = Process(); process.executableURL = executable
            process.arguments = ["worker", directory.path, index.isMultiple(of: 2) ? "GMAIL" : "gmail"]
            try process.run(); processes.append(process)
        }
        for process in processes { process.waitUntilExit() }
        precondition(processes.filter { $0.terminationStatus == 0 }.count == 1, "Exactly one cross-process unique-key winner required")
        precondition(processes.filter { $0.terminationStatus == 10 }.count == 31, "Every other save must report duplicate")
        let firstRecords = try store.load()
        precondition(firstRecords.count == 1)
        processes = []
        for index in 0..<32 {
            let process = Process(); process.executableURL = executable
            process.arguments = ["worker", directory.path, "unique_\(index)"]
            try process.run(); processes.append(process)
        }
        for process in processes { process.waitUntilExit() }
        precondition(processes.allSatisfy { $0.terminationStatus == 0 }, "Independent saves must succeed")
        let records = try store.load()
        precondition(records.count == 33, "Atomic read-modify-write must not lose concurrent records")
        precondition(Set(records.map(\.id)).count == 33)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(Set(files.map(\.lastPathComponent)) == ["records.json", "store.lock"], "No temporary content left behind")
        print("PASS: 32 competing processes, one case-insensitive winner; 32 independent processes, no lost writes; no temporary files.")
    }
}
