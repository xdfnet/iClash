import Foundation

@MainActor
protocol KernelServiceControlling: AnyObject {
    var isRunning: Bool { get }
    func isSystemProxyEnabled() -> Bool
    func stop()
    func start() async throws
    func setSystemProxy(enabled: Bool) throws
    func updateKernelVersion(_ version: String)
    func fetchKernelVersion() async
}

@MainActor
protocol KernelUpdateManaging: AnyObject {
    func updateKernel() async -> KernelUpdateResult
    func installKernel(from downloadedPath: URL) throws
    func cleanupTemporaryDownload()
}

enum KernelUpdateFlowResult {
    case alreadyLatest
    case updated(version: String, restarted: Bool)
    case failed(Error)
}

@MainActor
final class KernelUpdateCoordinator {
    private let service: KernelServiceControlling
    private let updater: KernelUpdateManaging

    init(service: KernelServiceControlling, updater: KernelUpdateManaging) {
        self.service = service
        self.updater = updater
    }

    func performUpdate() async -> KernelUpdateFlowResult {
        let wasRunning = service.isRunning
        let wasProxyEnabled = service.isSystemProxyEnabled()
        let result = await updater.updateKernel()

        switch result {
        case .alreadyLatest:
            return .alreadyLatest

        case .failed(let error):
            return .failed(error)

        case .ready(let newVersion, let downloadedPath):
            do {
                if wasRunning {
                    service.stop()
                }

                try updater.installKernel(from: downloadedPath)
                service.updateKernelVersion(newVersion)

                if wasRunning {
                    try await service.start()
                    if wasProxyEnabled {
                        try service.setSystemProxy(enabled: true)
                    }
                    await service.fetchKernelVersion()
                }

                return .updated(version: newVersion, restarted: wasRunning)
            } catch {
                updater.cleanupTemporaryDownload()
                if wasRunning {
                    try? await service.start()
                    if wasProxyEnabled {
                        try? service.setSystemProxy(enabled: true)
                    }
                }
                return .failed(error)
            }
        }
    }
}

extension MihomoService: KernelServiceControlling {}
extension KernelUpdater: KernelUpdateManaging {}
