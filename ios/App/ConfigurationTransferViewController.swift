import UIKit
import UniformTypeIdentifiers

final class ConfigurationTransferViewController: UITableViewController, UIDocumentPickerDelegate {
    private let sync = MobileConfiguration.sync
    private var exportURL: URL?
    private var exportPassword: String?
    private var linkExport = false
    private var linkImport = false
    private var working = false
    private var polling: Timer?
    private var exportDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-configuration-export", isDirectory: true) }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Sync and Transfer"
        try? FileManager.default.removeItem(at: exportDirectory)
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 60
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); sync.refresh(); tableView.reloadData()
        polling = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tableView.reloadData() }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); polling?.invalidate(); polling = nil }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 5 + (sync.hasConflict ? 2 : 0) : 2
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Encrypted File Sync" : "Encrypted JSON Transfer" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Choose the same file in iCloud Drive on each device. Syncs Polish Dictation and Sentence Punctuation. Open vvhisper to receive changes. Cloud delivery may take time."
            : "Use the same password on Mac, iOS and Android. Keep a copy; it cannot be recovered. Imported files replace only included values. Credentials are supplied by the app."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        if path.section == 0 {
            cell.textLabel?.text = [sync.status, "Create Sync File", "Link Existing File", "Sync Now", "Disconnect File",
                                   "Keep This Device’s Values", "Keep File Values"][path.row]
            if path.row == 0 { cell.textLabel?.font = .preferredFont(forTextStyle: .footnote); cell.selectionStyle = .none }
        } else { cell.textLabel?.text = ["Export Settings", "Import Encrypted JSON"][path.row] }
        cell.isUserInteractionEnabled = !working && !sync.busy && !(path.section == 0 && (path.row == 0 || ((path.row == 3 || path.row == 4) && !sync.enabled)))
        if !cell.isUserInteractionEnabled && !(path.section == 0 && path.row == 0) { cell.textLabel?.textColor = .secondaryLabel }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        if path.section == 0 {
            switch path.row {
            case 1: askPassword(creating: true) { self.exportFile(keys: false, link: true, password: $0) }
            case 2: chooseFile(link: true)
            case 3: sync.refresh()
            case 4: sync.disconnect()
            case 5: sync.refresh(resolution: .local)
            case 6: sync.refresh(resolution: .file)
            default: break
            }
        } else if path.row == 1 { chooseFile(link: false) }
        else { askPassword(creating: true) { self.exportFile(keys: false, link: false, password: $0) } }
        tableView.reloadData()
    }
    private func chooseFile(link: Bool) {
        linkImport = link
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: false)
        picker.delegate = self; present(picker, animated: true)
    }
    private func exportFile(keys: Bool, link: Bool, password: String) {
        working = true; tableView.reloadData()
        Task {
            defer { working = false; tableView.reloadData() }
            do {
                clearExport()
                let document = try sync.document(includeKeys: keys)
                let data = try await Task.detached { try EncryptedConfiguration.seal(document, password: password) }.value
                let folder = exportDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("vvhisper-config.json"); exportURL = url
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                exportPassword = link ? password : nil; linkExport = link
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                picker.delegate = self; present(picker, animated: true)
            } catch { clearExport(); notice(safeError(error)) }
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true) { self.handlePicked(urls) }
    }
    private func handlePicked(_ urls: [URL]) {
        guard let url = urls.first else { clearExport(); return }
        if exportURL != nil {
            let password = exportPassword, link = linkExport
            clearExport()
            if link, let password {
                Task {
                    do { try await sync.connect(url, password: password); tableView.reloadData() }
                    catch { notice("File exported. Choose Link Existing File to select the saved copy and enter its password.") }
                }
            }
            return
        }
        let link = linkImport
        askPassword(creating: false) { password in
            self.working = true; self.tableView.reloadData()
            Task {
                defer { self.working = false; self.tableView.reloadData() }
                do {
                    if link { try await self.sync.connect(url, password: password) }
                    else {
                        let value = try await Task.detached { try EncryptedConfiguration.open(ConfigurationFile.read(url), password: password) }.value
                        self.confirm(title: "Import configuration?", message: "Replace the included polishing and punctuation settings? Credentials and device settings stay unchanged.") {
                            do { try self.sync.apply(value); self.sync.refresh(); self.notice("Configuration imported.") }
                            catch { self.notice(self.safeError(error)) }
                        }
                    }
                } catch { self.notice(self.safeError(error)) }
            }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { clearExport() }
    private func clearExport() {
        if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
        exportURL = nil; exportPassword = nil; linkExport = false
    }
    private func askPassword(creating: Bool, action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: creating ? "Protect Configuration" : "Unlock Configuration",
            message: creating ? "Choose a long, unique password (at least 8 characters). Keep it for your other devices."
                              : "Enter the file password. Linking saves it only in this device’s local Keychain.", preferredStyle: .alert)
        alert.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "Password"; $0.textContentType = creating ? .newPassword : .password }
        if creating { alert.addTextField { $0.isSecureTextEntry = true; $0.placeholder = "Confirm password"; $0.textContentType = .newPassword } }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
            let value = alert.textFields?.first?.text ?? ""
            guard !creating || value == alert.textFields?.last?.text else { self.notice("Passwords don’t match."); return }
            alert.textFields?.forEach { $0.text = "" }
            do { try EncryptedConfiguration.validatePassword(value); action(value) }
            catch { self.notice(self.safeError(error)) }
        })
        present(alert, animated: true)
    }
    private func confirm(title: String, message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Import", style: .default) { _ in action() })
        present(alert, animated: true)
    }
    private func safeError(_ error: Error) -> String { (error as? ConfigurationError)?.localizedDescription ?? "Couldn’t access the configuration file. Local settings are unchanged." }
    private func notice(_ message: String) {
        tableView.reloadData(); let alert = UIAlertController(title: "Configuration", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
