//
//  SessionRefreshService.swift
//  Bitkit
//
//  Background service for refreshing Pubky sessions before they expire.
//  Uses BGAppRefreshTask for background refresh when app is suspended.
//

import BackgroundTasks
import Foundation

/// Service for managing background session refresh.
///
/// Monitors Pubky sessions for expiration and refreshes them proactively
/// to ensure uninterrupted service.
public final class SessionRefreshService {
    
    public static let shared = SessionRefreshService()
    
    // MARK: - Constants
    
    /// Background task identifier - must be registered in Info.plist
    public static let taskIdentifier = "to.bitkit.sessions.refresh"
    
    /// Refresh sessions expiring within this buffer (10 minutes)
    private let expiryBufferSeconds: TimeInterval = 600
    
    /// Minimum interval between refresh checks (1 hour)
    private let minimumRefreshInterval: TimeInterval = 3600
    
    private init() {}
    
    // MARK: - Registration
    
    /// Register the background task with BGTaskScheduler.
    /// Call this in AppDelegate.didFinishLaunchingWithOptions.
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleSessionRefresh(task: task as! BGAppRefreshTask)
        }
        Logger.info("SessionRefreshService: Registered background task", context: "SessionRefreshService")
    }
    
    /// Schedule the next background refresh.
    public func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumRefreshInterval)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            Logger.info("SessionRefreshService: Scheduled background refresh for \(request.earliestBeginDate?.description ?? "unknown")", context: "SessionRefreshService")
        } catch {
            Logger.error("SessionRefreshService: Failed to schedule: \(error)", context: "SessionRefreshService")
        }
    }
    
    // MARK: - Background Task Handler
    
    private func handleSessionRefresh(task: BGAppRefreshTask) {
        Logger.info("SessionRefreshService: Starting refresh", context: "SessionRefreshService")
        
        // Schedule next refresh
        scheduleBackgroundRefresh()
        
        let refreshTask = Task {
            do {
                try await refreshExpiringSessions()
                task.setTaskCompleted(success: true)
            } catch {
                Logger.error("SessionRefreshService: Refresh failed: \(error)", context: "SessionRefreshService")
                task.setTaskCompleted(success: false)
            }
        }
        
        task.expirationHandler = {
            refreshTask.cancel()
        }
    }
    
    // MARK: - Session Refresh Logic
    
    /// Refresh all sessions expiring within buffer.
    public func refreshExpiringSessions() async throws {
        let pubkyRingBridge = PubkyRingBridge.shared
        let now = Date()
        let expirationThreshold = now.addingTimeInterval(expiryBufferSeconds)
        
        let sessions = pubkyRingBridge.cachedSessions
        var refreshedCount = 0
        
        for session in sessions {
            // Check if session is expiring soon
            if let expiresAt = session.expiresAt, expiresAt < expirationThreshold {
                Logger.info("SessionRefreshService: Session for \(session.pubkey.prefix(12))... expires soon, refreshing", context: "SessionRefreshService")
                
                do {
                    try await refreshSession(session)
                    refreshedCount += 1
                } catch {
                    Logger.error("SessionRefreshService: Failed to refresh session for \(session.pubkey.prefix(12))...: \(error)", context: "SessionRefreshService")
                }
            }
        }
        
        // Also refresh PubkySDKService sessions
        try await PubkySDKService.shared.refreshExpiringSessions()
        
        Logger.info("SessionRefreshService: Refreshed \(refreshedCount) sessions", context: "SessionRefreshService")
    }
    
    /// Refresh a single session.
    private func refreshSession(_ session: PubkyRingSession) async throws {
        // For now, we rely on PubkySDKService to handle session refresh
        // If the session is from Pubky-ring, we would need to request a new session
        // This is a simplified implementation - in production, you'd re-authenticate
        
        // Attempt to refresh via PubkySDKService
        let sdkService = PubkySDKService.shared
        try await sdkService.refreshSession(pubkey: session.pubkey)
    }
    
    /// Check if any sessions need refresh (for foreground checks).
    public func checkAndRefreshIfNeeded() async {
        let pubkyRingBridge = PubkyRingBridge.shared
        let now = Date()
        let expirationThreshold = now.addingTimeInterval(expiryBufferSeconds)
        
        let sessions = pubkyRingBridge.cachedSessions
        let expiringSessions = sessions.filter { session in
            guard let expiresAt = session.expiresAt else { return false }
            return expiresAt < expirationThreshold
        }
        
        if !expiringSessions.isEmpty {
            Logger.info("SessionRefreshService: Found \(expiringSessions.count) sessions expiring soon", context: "SessionRefreshService")
            
            do {
                try await refreshExpiringSessions()
            } catch {
                Logger.error("SessionRefreshService: Foreground refresh failed: \(error)", context: "SessionRefreshService")
            }
        }
    }
    
    /// Get the earliest session expiration time (for scheduling).
    public func earliestSessionExpiration() -> Date? {
        let sessions = PubkyRingBridge.shared.cachedSessions
        let expirations = sessions.compactMap { $0.expiresAt }
        return expirations.min()
    }
}

