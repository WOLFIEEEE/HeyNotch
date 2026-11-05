import Combine
import Foundation

@MainActor
final class AutomationCoordinator: ObservableObject {
    static let shared = AutomationCoordinator()
    @Published private(set) var status = "Agent access is off."
    @Published private(set) var recentActivity: [String] = []
    private let access: AutomationAccessStore
    private lazy var engine: AutomationTaskEngine = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyNotch/Automation", isDirectory: true)
        return AutomationTaskEngine(board: TaskController.shared, journalURL: directory.appendingPathComponent("operations-v1.json"))
    }()
    private var observer: AnyCancellable?
    private var server: AutomationHTTPServer?
    private var accessEpoch = UUID()

    private init() {
        access = .shared
    }

    func start() {
        guard observer == nil else { return }
        server = AutomationHTTPServer(handler: { [weak self] request in
            guard let self else { return AutomationHTTPServer.error("unavailable", "HeyNotch is shutting down.") }
            return await self.handle(request)
        }, status: { [weak self] message in
            Task { @MainActor in self?.status = message }
        })
        observer = access.$enabled.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            self.accessEpoch = UUID()
            if enabled { self.server?.start() } else { self.server?.stop() }
        }
    }

    func retireClient(_ id: String) async {
        if !(await engine.retireClient(id)) {
            status = "Connection revoked. Its old operation records could not be removed; access remains blocked."
        }
    }

    private func handle(_ request: AutomationHTTPRequest) async -> Data {
        guard let grant = access.authenticate(clientID: request.clientID, token: request.token) else {
            return AutomationHTTPServer.error("unauthorized", "This connection is disabled or revoked. Reconnect in HeyNotch Settings > Agent access.")
        }
        let epoch = accessEpoch
        let context = AutomationContext(clientID: grant.id, allowedListIDs: grant.allowedListIDs, canWrite: grant.canWrite,
                                        authorizationCheck: { [weak self] in
            guard let self else { return false }
            return self.accessEpoch == epoch && self.access.enabled && self.access.grants.contains(where: { $0.id == grant.id })
        })
        let response = await engine.execute(request.body, context: context)
        // Activity contains operation names and outcomes only: no task contents,
        // tokens, request arguments, or full response data are logged.
        if let requestObject = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let tool = requestObject["tool"] as? String,
           ["create_task", "update_task", "move_task", "set_task_completed"].contains(tool) {
            let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
            let succeeded = object?["ok"] as? Bool == true
            let labels = ["create_task": "Create task", "update_task": "Edit task", "move_task": "Move task", "set_task_completed": "Change completion"]
            let time = Date().formatted(date: .omitted, time: .shortened)
            recentActivity.insert("\(time) · \(grant.name) · \(labels[tool] ?? "Task action") · \(succeeded ? "Saved" : "Needs attention")", at: 0)
            recentActivity = Array(recentActivity.prefix(10))
        }
        return response
    }
}
