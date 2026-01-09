import BackgroundTasks
import SwiftUI
import UserNotifications

// MARK: - Quick Action Notification

// Communication bridge between delegates and SwiftUI views
extension Notification.Name {
    static let quickActionSelected = Notification.Name("quickActionSelected")
    static let paykitPayContact = Notification.Name("paykitPayContact")
    static let paykitPaymentFailed = Notification.Name("paykitPaymentFailed")
    static let paykitRequestPayment = Notification.Name("paykitRequestPayment")
    static let paykitSubscriptionProposal = Notification.Name("paykitSubscriptionProposal")
    static let profileUpdated = Notification.Name("profileUpdated")
    static let incomingPaymentNotification = Notification.Name("incomingPaymentNotification")
}

class AppDelegate: NSObject, UIApplicationDelegate {
    // MARK: - App Launch

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        UNUserNotificationCenter.current().delegate = self
        
        // Register time-sensitive notification categories for incoming payments
        registerNotificationCategories()

        // Check notification authorization status at launch and re-register with APN if granted
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .authorized {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        
        // Register Paykit background tasks
        SubscriptionBackgroundService.shared.registerBackgroundTask()
        PaykitPollingService.shared.registerBackgroundTask()
        SessionRefreshService.shared.registerBackgroundTask()

        return true
    }
    
    private func registerNotificationCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_NOW",
            title: "Open Now",
            options: [.foreground]
        )
        
        let incomingPayment = UNNotificationCategory(
            identifier: "INCOMING_PAYMENT",
            actions: [openAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([incomingPayment])
        Logger.debug("🔔 Registered notification categories", context: "AppDelegate")
    }

    // MARK: - Scene Configuration

    // Required for SwiftUI apps to handle quick actions
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // MARK: - App Termination

    func applicationWillTerminate(_ application: UIApplication) {
        try? StateLocker.unlock(.lightning)
    }
    
    // MARK: - URL Handling
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Route bitkit:// URLs to PubkyRingBridge for Paykit/Pubky-ring callbacks
        if url.scheme == "bitkit" {
            Logger.info("AppDelegate: Received bitkit:// URL: \(url.absoluteString)", context: "AppDelegate")
            return PubkyRingBridge.shared.handleCallback(url: url)
        }
        return false
    }
}

// MARK: - Push Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        PushNotificationManager.shared.updateDeviceToken(token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.error("🔔 AppDelegate: didFailToRegisterForRemoteNotificationsWithError: \(error)")
    }
    
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Logger.info("🔔 Silent push received", context: "AppDelegate")
        
        guard let type = userInfo["type"] as? String, type == "incoming_htlc_wake" else {
            Logger.debug("🔔 Silent push is not an HTLC wake type, ignoring", context: "AppDelegate")
            completionHandler(.noData)
            return
        }
        
        Logger.info("🔔 Processing incoming HTLC wake push in background", context: "AppDelegate")
        let startTime = Date()
        
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = application.beginBackgroundTask(withName: "ProcessIncomingHTLC") {
            Logger.info("🔔 Background task expiring, stopping node", context: "AppDelegate")
            Task {
                try? await LightningService.shared.stop()
            }
            application.endBackgroundTask(backgroundTaskID)
        }
        
        Task {
            defer {
                let elapsed = Date().timeIntervalSince(startTime)
                Logger.info("🔔 Background HTLC processing completed in \(String(format: "%.2f", elapsed))s", context: "AppDelegate")
                application.endBackgroundTask(backgroundTaskID)
            }
            
            do {
                try await processIncomingHTLCInBackground(userInfo: userInfo)
                completionHandler(.newData)
            } catch {
                Logger.error("🔔 Background HTLC processing failed: \(error)", context: "AppDelegate")
                completionHandler(.failed)
            }
        }
    }
    
    private func processIncomingHTLCInBackground(userInfo: [AnyHashable: Any]) async throws {
        guard !StateLocker.isLocked(.lightning) else {
            Logger.debug("🔔 Lightning already locked, skipping background processing", context: "AppDelegate")
            return
        }
        
        try StateLocker.lock(.lightning, wait: 5)
        defer { try? StateLocker.unlock(.lightning) }
        
        let walletIndex = 0
        
        try await LightningService.shared.setup(walletIndex: walletIndex)
        try await LightningService.shared.start { event in
            Logger.debug("🔔 Background LDK event: \(event)", context: "AppDelegate")
        }
        
        try await LightningService.shared.connectToTrustedPeers()
        try await LightningService.shared.sync()
        
        try await Task.sleep(nanoseconds: 5_000_000_000)
        
        try await LightningService.shared.stop()
    }

    // Foreground notification presentation
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        Logger.debug("🔔 AppDelegate: willPresent notification called")
        Logger.debug("🔔 AppDelegate: UserInfo: \(userInfo)")
        Logger.debug("🔔 AppDelegate: Notification content: \(notification.request.content)")

        completionHandler([[.banner, .badge, .sound]])
    }

    // Handle taps on notifications
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        PushNotificationManager.shared.handleNotification(userInfo)

        // TODO: if user tapped on an incoming tx we should open it on that tx view
        completionHandler()
    }
}

// MARK: - SwiftUI App

@main
struct BitkitApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        UIWindow.appearance().overrideUserInterfaceStyle = .dark
        _ = ToastWindowManager.shared
    }

    var body: some Scene {
        WindowGroup {
            if Env.isUnitTest {
                Text("Running tests...")
            } else {
                ContentView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
