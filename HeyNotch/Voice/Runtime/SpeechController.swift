import Combine
import Foundation

@MainActor
final class SpeechController: ObservableObject {
    static let shared = SpeechController()
    let store = SpeechModelStore.shared
    let engine = LocalSpeechEngine()
    @Published private(set) var ready = false
    @Published private(set) var working = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = "Download and prepare a speech model to begin."
    @Published private(set) var installed: Set<String> = []
    private var job: Task<Void, Never>?
    private var generation = UUID()
    private var idle: Task<Void, Never>?
    private var useOwners: Set<String> = []
    @Published private(set) var isInUse = false
    var models: [SpeechModelManifest] { store.models }
    var selected: SpeechModelManifest? {
        let id = UserDefaults.standard.string(forKey: "voice.model") ?? "turbo"
        return models.first { $0.id == id }
    }

    func refreshInstalled() async {
        var found = Set<String>()
        for model in models where await store.installed(model) { found.insert(model.id) }
        installed = found
    }

    func prepare(allowDownload: Bool) {
        guard !working, !isInUse, let selected else { return }
        idle?.cancel(); generation = UUID(); let id = generation
        ready = false; working = true; progress = 0
        status = allowDownload ? "Downloading and checking model files…" : "Checking the installed speech model…"
        job = Task {
            do {
                let folder = try await store.prepare(selected, allowDownload: allowDownload) { [weak self] value in
                    Task { @MainActor in if self?.generation == id { self?.progress = value } }
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                status = "Preparing speech recognition. Wait for Ready before speaking…"
                try await engine.load(folder: folder)
                try Task.checkCancellation()
                guard generation == id else { return }
                ready = true; status = "Ready · \(selected.name)"
            } catch {
                if generation == id {
                    status = error is CancellationError ? "Preparation cancelled. Verified files are kept for retry." : (error as? VoiceError)?.localizedDescription ?? "The speech model could not be prepared. Delete it and download it again."
                }
            }
            if generation == id { working = false; job = nil; await refreshInstalled(); scheduleIdleUnload() }
        }
    }

    func cancel() {
        job?.cancel()
        status = "Cancelling model preparation…"
    }

    func unload() async {
        guard !working, !isInUse else { return }
        idle?.cancel(); ready = false
        await engine.unload()
        status = "Model unloaded. Prepare it again before speaking."
    }

    func delete(_ model: SpeechModelManifest) async {
        guard !working, !isInUse else { return }
        await unload()
        do { try await store.delete(model); status = "\(model.name) removed from this Mac." }
        catch { status = "The model could not be removed. Try again." }
        await refreshInstalled()
    }

    func beginUse(_ owner: String = "dictation") { useOwners.insert(owner); isInUse = true; idle?.cancel(); idle = nil }
    func endUse(_ owner: String = "dictation") { useOwners.remove(owner); isInUse = !useOwners.isEmpty; scheduleIdleUnload() }
    func scheduleIdleUnload() {
        idle?.cancel()
        let minutes = UserDefaults.standard.object(forKey: "voice.idleUnloadMinutes") as? Int ?? 5
        guard ready, !isInUse, minutes > 0 else { return }
        idle = Task {
            do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
            await unload()
        }
    }
}
