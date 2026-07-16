import BackgroundTasks
import Foundation

protocol ContinuedProcessingTaskHandle: AnyObject, Sendable {
    var progress: Progress { get }
    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void)
    func setCompleted(success: Bool)
}

protocol ImportTaskScheduling {
    func register(
        identifier: String,
        launchHandler: @escaping @Sendable (any ContinuedProcessingTaskHandle) -> Void
    )
    func submit(identifier: String, title: String, subtitle: String) throws
}

struct BGTaskSchedulerAdapter: ImportTaskScheduling {
    func register(
        identifier: String,
        launchHandler: @escaping @Sendable (any ContinuedProcessingTaskHandle) -> Void
    ) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            launchHandler(BGContinuedTaskHandle(task: continued))
        }
    }

    func submit(identifier: String, title: String, subtitle: String) throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: title, subtitle: subtitle
        )
        request.strategy = .queue
        try BGTaskScheduler.shared.submit(request)
    }
}

final class BGContinuedTaskHandle: ContinuedProcessingTaskHandle, @unchecked Sendable {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
    }

    var progress: Progress { task.progress }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func setCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class ImportTaskRunner {
    static let importTailUnit: Int64 = 1_000_000
    static let defaultIdentifierPrefix = "dev.karpovich.allspeak.import"

    private let downloader: SessionDownloader
    private let scheduler: any ImportTaskScheduling
    private let identifierPrefix: String

    init(
        downloader: SessionDownloader,
        scheduler: any ImportTaskScheduling,
        identifierPrefix: String = ImportTaskRunner.defaultIdentifierPrefix
    ) {
        self.downloader = downloader
        self.scheduler = scheduler
        self.identifierPrefix = identifierPrefix
    }

    static func identifier(prefix: String, serverID: UUID, attemptID: UUID) -> String {
        "\(prefix).\(serverID.uuidString.lowercased()).\(attemptID.uuidString.lowercased())"
    }

    func run(
        serverID: UUID,
        files: [CatalogFileRequest],
        title: String,
        subtitle: String = "",
        attemptID: UUID = UUID(),
        finish: @escaping @Sendable () async throws -> Void
    ) async {
        let identifier = Self.identifier(prefix: identifierPrefix, serverID: serverID, attemptID: attemptID)
        let downloadBytes = files.reduce(Int64(0)) { $0 + $1.size }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.register(identifier: identifier) { handle in
                Task { @MainActor in
                    await self.runPipeline(
                        handle: handle, serverID: serverID, files: files,
                        downloadBytes: downloadBytes, finish: finish
                    )
                    continuation.resume()
                }
            }

            do {
                try scheduler.submit(identifier: identifier, title: title, subtitle: subtitle)
            } catch {
                Task { @MainActor in
                    await self.runInProcess(serverID: serverID, files: files, finish: finish)
                    continuation.resume()
                }
            }
        }
    }

    private func runPipeline(
        handle: any ContinuedProcessingTaskHandle,
        serverID: UUID,
        files: [CatalogFileRequest],
        downloadBytes: Int64,
        finish: @escaping @Sendable () async throws -> Void
    ) async {
        // The tail slice keeps progress advancing after the last downloaded byte so the
        // system never sees a silent (100%-stuck) task while the import/hash phase runs.
        handle.progress.totalUnitCount = downloadBytes + Self.importTailUnit
        handle.progress.completedUnitCount = 0

        // The whole pipeline - download AND the import/apply tail - runs inside one cancellable
        // task so expiration reaches finish() too. If finish() ignores cooperative cancellation
        // (a quick Core Data write) it completes and success is reported truthfully; if it is
        // interrupted it throws and the task is reported failed with staging retained.
        let work = Task { @MainActor in
            try await self.downloader.start(serverID: serverID, files: files, into: handle.progress)
            handle.progress.completedUnitCount = downloadBytes
            try await finish()
            handle.progress.completedUnitCount = downloadBytes + Self.importTailUnit
        }
        handle.setExpirationHandler { work.cancel() }

        do {
            try await work.value
            handle.setCompleted(success: true)
        } catch {
            handle.setCompleted(success: false)
        }
    }

    private func runInProcess(
        serverID: UUID,
        files: [CatalogFileRequest],
        finish: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await downloader.start(serverID: serverID, files: files)
            try await finish()
        } catch {
            // In-process fallback: the downloader's own state reflects the failure.
        }
    }
}
