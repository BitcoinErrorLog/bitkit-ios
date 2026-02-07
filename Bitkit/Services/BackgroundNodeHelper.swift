import Foundation

enum BackgroundNodeError: Error {
    case timeout
    case nodeAlreadyLocked
    case nodeStartFailed(Error)
}

actor BackgroundNodeHelper {
    static let shared = BackgroundNodeHelper()
    
    private init() {}
    
    func performBoundedNodeWork<T>(
        timeout: TimeInterval = 30,
        walletIndex: Int = 0,
        work: @escaping () async throws -> T
    ) async throws -> T {
        guard !StateLocker.isLocked(.lightning) else {
            Logger.info("🔔 Node already locked, cannot perform background work", context: "BackgroundNodeHelper")
            throw BackgroundNodeError.nodeAlreadyLocked
        }
        
        let startTime = Date()
        Logger.info("🔔 Starting bounded node work", context: "BackgroundNodeHelper")
        
        try await StateLocker.lock(.lightning, wait: 5)
        defer {
            try? StateLocker.unlock(.lightning)
            let elapsed = Date().timeIntervalSince(startTime)
            Logger.info("🔔 Bounded node work completed in \(String(format: "%.2f", elapsed))s", context: "BackgroundNodeHelper")
        }
        
        do {
            if !LightningService.shared.isNodeAvailable {
                try await LightningService.shared.setup(walletIndex: walletIndex)
                try await LightningService.shared.start { _ in }
            }
            
            try await LightningService.shared.connectToTrustedPeers()
            
            let result = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await work()
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw BackgroundNodeError.timeout
                }
                
                guard let result = try await group.next() else {
                    throw BackgroundNodeError.timeout
                }
                
                group.cancelAll()
                return result
            }
            
            try await LightningService.shared.stop()
            
            return result
        } catch {
            try? await LightningService.shared.stop()
            throw error
        }
    }
    
    func performSyncAndWait(walletIndex: Int = 0, waitDuration: TimeInterval = 5) async throws {
        try await performBoundedNodeWork(timeout: 30, walletIndex: walletIndex) {
            try await LightningService.shared.sync()
            try await Task.sleep(nanoseconds: UInt64(waitDuration * 1_000_000_000))
        }
    }
}
