import SwiftUI
// PaykitMobile types are part of this module (no import needed)

struct MainNavView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var notificationManager: PushNotificationManager
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var wallet: WalletViewModel
    @Environment(\.scenePhase) var scenePhase

    @State private var showClipboardAlert = false
    @State private var clipboardUri: String?

    // Delay constants for clipboard processing
    private static let nodeReadyDelayNanoseconds: UInt64 = 500_000_000 // 0.5 seconds
    private static let statePropagationDelayNanoseconds: UInt64 = 500_000_000 // 0.5 seconds

    var body: some View {
        NavigationStack(path: $navigation.path) {
            navigationContent
        }
        .sheet(
            item: $sheets.addTagSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in AddTagSheet(config: config)
        }
        .sheet(
            item: $sheets.boostSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in BoostSheet(config: config)
        }
        .sheet(
            item: $sheets.appUpdateSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.ignoreAppUpdate()
            }
        ) {
            config in AppUpdateSheet(config: config)
        }
        .sheet(
            item: $sheets.backupSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.ignoreBackup()
            }
        ) {
            config in BackupSheet(config: config)
        }
        .sheet(
            item: $sheets.giftSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in GiftSheet(config: config)
        }
        .sheet(
            item: $sheets.highBalanceSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.ignoreHighBalance()
            }
        ) {
            config in HighBalanceSheet(config: config)
        }
        .sheet(
            item: $sheets.lnurlAuthSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in LnurlAuthSheet(config: config)
        }
        .sheet(
            item: $sheets.lnurlWithdrawSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in LnurlWithdrawSheet(config: config)
        }
        .sheet(
            item: $sheets.notificationsSheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.hasSeenNotificationsIntro = true
            }
        ) {
            config in NotificationsSheet(config: config)
        }
        .sheet(
            item: $sheets.receiveSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ReceiveSheet(config: config)
        }
        .sheet(
            item: $sheets.receivedTxSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ReceivedTx(config: config)
        }
        .sheet(
            item: $sheets.scannerSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ScannerSheet(config: config)
        }
        .sheet(
            item: $sheets.securitySheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in SecuritySheet(config: config)
        }
        .sheet(
            item: $sheets.quickpaySheetItem,
            onDismiss: {
                sheets.hideSheet()
                app.hasSeenQuickpayIntro = true
            }
        ) {
            config in QuickpaySheet(config: config)
        }
        .sheet(
            item: $sheets.sendSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in SendSheet(config: config)
        }
        .sheet(
            item: $sheets.forceTransferSheetItem,
            onDismiss: {
                sheets.hideSheet()
            }
        ) {
            config in ForceTransferSheet(config: config)
        }
        .accentColor(.white)
        .overlay {
            TabBar()
            DrawerView()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // Update notification permission in case user changed it in OS settings
                notificationManager.updateNotificationPermission()

                guard settings.readClipboard else { return }

                handleClipboard()
            }
        }
        .onChange(of: notificationManager.authorizationStatus) { newStatus in
            // Handle notification permission changes
            if newStatus == .authorized {
                settings.enableNotifications = true
                notificationManager.requestPermission()
            } else {
                settings.enableNotifications = false
                notificationManager.unregister()
            }
        }
        .onChange(of: notificationManager.deviceToken) { token in
            // Register with backend if device token changed and notifications are enabled
            if let token, settings.enableNotifications {
                Task {
                    do {
                        try await notificationManager.registerWithBackend(deviceToken: token)
                    } catch {
                        Logger.error("Failed to sync push notifications with backend: \(error)")
                        app.toast(
                            type: .error,
                            title: tTodo("Notification Registration Failed"),
                            description: tTodo("Bitkit was unable to register for push notifications.")
                        )
                    }
                }
            }
        }
        .onChange(of: settings.enableNotifications) { newValue in
            // Handle notification enable/disable
            if newValue {
                // Request permission in case user was not prompted yet
                notificationManager.requestPermission()

                if let token = notificationManager.deviceToken {
                    Task {
                        do {
                            try await notificationManager.registerWithBackend(deviceToken: token)
                        } catch {
                            Logger.error("Failed to sync push notifications: \(error)")
                            app.toast(
                                type: .error,
                                title: tTodo("Notification Registration Failed"),
                                description: tTodo("Bitkit was unable to register for push notifications.")
                            )
                        }
                    }
                }
            } else {
                // Disable notifications (unregister)
                notificationManager.unregister()
            }
        }
        .onOpenURL { url in
            Task {
                Logger.info("Received deeplink: \(url.absoluteString)")

                // Handle Pubky-ring callbacks first (session, keypair, profile, follows)
                if PubkyRingBridge.shared.handleCallback(url: url) {
                    Logger.info("Handled Pubky-ring callback: \(url.host ?? "unknown")")
                    return
                }

                // Check if this is a Paykit payment request using secure validator
                if PaykitDeepLinkValidator.isPaykitURL(url) {
                    // Validate before processing
                    switch PaykitDeepLinkValidator.validate(url) {
                    case .valid(let requestId, let fromPubkey):
                        await handlePaymentRequestDeepLink(
                            requestId: requestId,
                            fromPubkey: fromPubkey,
                            app: app,
                            sheets: sheets
                        )
                    case .invalid(let reason):
                        Logger.error("Invalid Paykit deep link: \(reason)", context: "MainNavView")
                        app.toast(type: .error, title: "Invalid Request", description: reason)
                    }
                    return
                }
                
                #if DEBUG
                // Test handler for publishing a payment request (DEBUG builds only)
                // URL: bitkit://test-publish-request?amount=42069&to=<recipientPubkey>&description=Test
                if url.scheme == "bitkit" && url.host == "test-publish-request" {
                    await handleTestPublishRequest(url: url, app: app)
                    return
                }
                #endif

                // Handle other deep links (Bitcoin, Lightning, etc.)
                do {
                    try await app.handleScannedData(url.absoluteString)
                    PaymentNavigationHelper.openPaymentSheet(
                        app: app,
                        currency: currency,
                        settings: settings,
                        sheetViewModel: sheets
                    )
                } catch {
                    Logger.error(error, context: "Failed to handle deeplink")
                    app.toast(
                        type: .error,
                        title: t("other__qr_error_header"),
                        description: t("other__qr_error_text")
                    )
                }
            }
        }
        .alert(
            t("other__clipboard_redirect_title"),
            isPresented: $showClipboardAlert
        ) {
            Button(t("common__ok")) {
                processClipboardUri()
            }
            Button(t("common__dialog_cancel"), role: .cancel) {
                clipboardUri = nil
            }
        } message: {
            Text(t("other__clipboard_redirect_msg"))
        }
    }

    // MARK: - Computed Properties for Better Organization

    @ViewBuilder
    private var navigationContent: some View {
        Group {
            switch navigation.activeDrawerMenuItem {
            case .wallet:
                HomeView()
            case .activity:
                AllActivityView()
            case .contacts:
                if app.hasSeenContactsIntro {
                    PaykitContactsView()
                } else {
                    ContactsIntroView()
                }
            case .profile:
                if app.hasSeenProfileIntro {
                    ProfileView()
                } else {
                    ProfileIntroView()
                }
            case .settings:
                MainSettings()
            case .shop:
                if app.hasSeenShopIntro {
                    ShopDiscover()
                } else {
                    ShopIntro()
                }
            case .widgets:
                if app.hasSeenWidgetsIntro {
                    WidgetsListView()
                } else {
                    WidgetsIntroView()
                }
            case .appStatus:
                AppStatusView()
            }
        }
        .navigationDestination(for: Route.self) { screenValue in
            switch screenValue {
            case .activityList: AllActivityView()
            case let .activityDetail(activity): ActivityItemView(item: activity)
            case let .activityExplorer(activity): ActivityExplorerView(item: activity)
            case .buyBitcoin: BuyBitcoinView()
            case .contacts: PaykitContactsView()
            case .contactsIntro: ContactsIntroView()
            case .savingsWallet: SavingsWalletView()
            case .spendingWallet: SpendingWalletView()
            case .transferIntro: TransferIntroView()
            case .fundingOptions: FundingOptions()
            case .spendingIntro: SpendingIntroView()
            case .spendingAmount: SpendingAmount()
            case let .spendingConfirm(order): SpendingConfirm(order: order)
            case let .spendingAdvanced(order): SpendingAdvancedView(order: order)
            case let .transferLearnMore(order): TransferLearnMoreView(order: order)
            case .settingUp: SettingUpView()
            case .fundingAdvanced: FundAdvancedOptions()
            case let .fundManual(nodeUri): FundManualSetupView(initialNodeUri: nodeUri)
            case .fundManualSuccess: FundManualSuccessView()
            case let .lnurlChannel(channelData): LnurlChannel(channelData: channelData)
            case .savingsIntro: SavingsIntroView()
            case .savingsAvailability: SavingsAvailabilityView()
            case .savingsConfirm: SavingsConfirmView()
            case .savingsAdvanced: SavingsAdvancedView()
            case .savingsProgress: SavingsProgressView()
            case .profile: ProfileView()
            case .profileIntro: ProfileIntroView()
            case .scanner: ScannerScreen()

            // Shop
            case .shopIntro: ShopIntro()
            case .shopDiscover: ShopDiscover()
            case let .shopMain(page): ShopMain(page: page)
            case .shopMap: ShopMap()

            // Widgets
            case .widgetsIntro: WidgetsIntroView()
            case .widgetsList: WidgetsListView()
            case let .widgetDetail(widgetType): WidgetDetailView(id: widgetType)
            case let .widgetEdit(widgetType): WidgetEditView(id: widgetType)

            // Settings
            case .settings: MainSettings()
            case .generalSettings: GeneralSettingsView()
            case .securitySettings: SecurityPrivacySettingsView()
            case .backupSettings: BackupSettings()
            case .advancedSettings: AdvancedSettingsView()
            case .support: SupportView()
            case .about: AboutView()
            case .devSettings: DevSettingsView()

            // General settings
            case .languageSettings: LanguageSettingsScreen()
            case .currencySettings: LocalCurrencySettingsView()
            case .unitSettings: DefaultUnitSettingsView()
            case .transactionSpeedSettings: TransactionSpeedSettingsView()
            case .quickpay: QuickpaySettings()
            case .quickpayIntro: QuickpayIntroView()
            case .customSpeedSettings: CustomSpeedView()
            case .tagSettings: TagSettingsView()
            case .widgetsSettings: WidgetsSettingsView()
            case .notifications: NotificationsSettings()
            case .notificationsIntro: NotificationsIntro()

            // Security settings
            case .disablePin: DisablePinView()
            case .changePin: PinChangeView()

            // Backup settings
            case .resetAndRestore: ResetAndRestore()

            // Support settings
            case .reportIssue: ReportIssue()
            case .appStatus: AppStatusView()

            // Advanced settings
            case .coinSelection: CoinSelectionSettingsView()
            case .connections: LightningConnectionsView()
            case let .connectionDetail(channelId): LightningConnectionDetailView(channelId: channelId)
            case let .closeConnection(channel: channel): CloseConnectionConfirmation(channel: channel)
            
            // Paykit routes
            case .paykitDashboard: PaykitDashboardView()
            case .paykitContacts: PaykitContactsView()
            case .paykitContactDiscovery: ContactDiscoveryView()
            case .paykitReceipts: PaykitReceiptsView()
            case .paykitReceiptDetail(let receiptId): ReceiptDetailLookupView(receiptId: receiptId)
            case .paykitSubscriptions: PaykitSubscriptionsView()
            case .paykitAutoPay: PaykitAutoPayView()
            case .paykitPaymentRequests: PaykitPaymentRequestsView()
            case .paykitNoisePayment: NoisePaymentView()
            case .paykitPrivateEndpoints: PrivateEndpointsView()
            case .paykitRotationSettings: RotationSettingsView()
            case .paykitSessionManagement: SessionManagementView()
            case .node: NodeStateView()
            case .electrumSettings: ElectrumSettingsScreen()
            case .rgsSettings: RgsSettingsScreen()
            case .addressViewer: AddressViewer()

            // Dev settings
            case .blocktankRegtest: BlocktankRegtestView()
            case .orders: ChannelOrders()
            case .logs: LogView()
            }
        }
    }

    private func handleClipboard() {
        Task { @MainActor in
            guard let uri = UIPasteboard.general.string else {
                return
            }

            // Store the URI and show alert
            clipboardUri = uri
            showClipboardAlert = true
        }
    }

    private func processClipboardUri() {
        guard let uri = clipboardUri else { return }

        Task { @MainActor in
            do {
                await wallet.waitForNodeToRun()
                try await Task.sleep(nanoseconds: Self.nodeReadyDelayNanoseconds)
                try await app.handleScannedData(uri)

                try await Task.sleep(nanoseconds: Self.statePropagationDelayNanoseconds)
                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(
                    type: .error,
                    title: t("other__qr_error_header"),
                    description: t("other__qr_error_text")
                )
            }

            // Clear stored URI after processing
            clipboardUri = nil
        }
    }
    
    #if DEBUG
    /// Test handler for publishing a payment request to Pubky storage (DEBUG only)
    /// URL: bitkit://test-publish-request?amount=42069&to=<recipientPubkey>&description=Test
    private func handleTestPublishRequest(url: URL, app: AppViewModel) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            app.toast(type: .error, title: "Invalid Test URL", description: "Could not parse test request URL")
            return
        }
        
        let amountString = queryItems.first(where: { $0.name == "amount" })?.value ?? "42069"
        let toPubkey = queryItems.first(where: { $0.name == "to" })?.value ?? ""
        let description = queryItems.first(where: { $0.name == "description" })?.value ?? "Test payment request"
        
        guard let amount = Int64(amountString) else {
            app.toast(type: .error, title: "Invalid Amount", description: "Amount must be a number")
            return
        }
        
        guard !toPubkey.isEmpty else {
            app.toast(type: .error, title: "Missing Recipient", description: "to parameter is required")
            return
        }
        
        // Get our pubkey from the session - try cached session first, fall back to test credentials
        let session: PubkySession
        if let cachedSession = PubkyRingBridge.shared.getAllSessions().first {
            session = cachedSession
        } else {
            // Use test iOS credentials for development
            // iOS: h73bexkpkkeus4uhaga4h1un8fgypyhiehw338k8owkjc6ummuso
            let testPubkey = "h73bexkpkkeus4uhaga4h1un8fgypyhiehw338k8owkjc6ummuso"
            let testSessionSecret = "h73bexkpkkeus4uhaga4h1un8fgypyhiehw338k8owkjc6ummuso:BA2Q8TWAM5FQTG7RYYK911E764"
            session = PubkySession(
                pubkey: testPubkey,
                sessionSecret: testSessionSecret,
                capabilities: ["read", "write"],
                createdAt: Date()
            )
            Logger.info("Using test iOS credentials for development", context: "MainNavView")
        }
        
        let requestId = "pr_test_\(Int(Date().timeIntervalSince1970))"
        let ourPubkey = session.pubkey
        
        // Create the payment request
        let request = BitkitPaymentRequest(
            id: requestId,
            fromPubkey: ourPubkey,
            toPubkey: toPubkey,
            amountSats: amount,
            currency: "BTC",
            methodId: "lightning",
            description: description,
            createdAt: Date(),
            expiresAt: nil,
            status: .pending,
            direction: .outgoing
        )
        
        Logger.info("Publishing test payment request: \(requestId) for \(amount) sats from \(ourPubkey.prefix(12))... to \(toPubkey.prefix(12))...", context: "MainNavView")
        
        // Import session into PubkySDKService first
        do {
            _ = try PubkySDKService.shared.importSession(pubkey: session.pubkey, sessionSecret: session.sessionSecret)
            Logger.info("Imported session for \(session.pubkey.prefix(12))...", context: "MainNavView")
        } catch {
            Logger.error("Failed to import session: \(error)", context: "MainNavView")
            app.toast(type: .error, title: "Session Import Failed", description: error.localizedDescription)
            return
        }
        
        // Configure DirectoryService with our session
        DirectoryService.shared.configureWithPubkySession(session)
        
        do {
            try await DirectoryService.shared.publishPaymentRequest(request)
            
            // Show success with the deep link for the receiver
            let receiverDeepLink = "bitkit://payment-request?requestId=\(requestId)&from=\(ourPubkey)"
            Logger.info("Published! Receiver deep link: \(receiverDeepLink)", context: "MainNavView")
            
            app.toast(type: .success, title: "Request Published!", description: "ID: \(requestId) - \(amount) sats")
            
            // Copy the receiver deep link to clipboard
            UIPasteboard.general.string = receiverDeepLink
            
        } catch {
            Logger.error("Failed to publish test request: \(error)", context: "MainNavView")
            app.toast(type: .error, title: "Publish Failed", description: error.localizedDescription)
        }
    }
    #endif
    
    /// Handle payment request deep links with pre-validated parameters.
    ///
    /// Parameters are already validated by `PaykitDeepLinkValidator` before this method is called.
    ///
    /// - Parameters:
    ///   - requestId: The validated payment request ID.
    ///   - fromPubkey: The validated sender's public key.
    ///   - app: The app view model.
    ///   - sheets: The sheet view model.
    private func handlePaymentRequestDeepLink(
        requestId: String,
        fromPubkey: String,
        app: AppViewModel,
        sheets: SheetViewModel
    ) async {
        Logger.info("Processing payment request: \(requestId) from \(fromPubkey.prefix(16))...", context: "MainNavView")
        
        // Check if PaykitManager is initialized, try to initialize if not
        if !PaykitManager.shared.isInitialized {
            do {
                try PaykitManager.shared.initialize()
            } catch {
                Logger.error("Failed to initialize PaykitManager: \(error)", context: "MainNavView")
                app.toast(type: .error, title: "Paykit Not Ready", description: "Please connect to Pubky Ring first")
                return
            }
        }
        
        // Get PaykitClient
        guard let paykitClient = PaykitManager.shared.client else {
            app.toast(type: .error, title: "Paykit Not Ready", description: "Paykit client not available")
            return
        }
        
        // Create autopay evaluator
        let autoPayViewModel = await AutoPayViewModel()
        
        // Create PaymentRequestService
        let paymentRequestStorage = PaymentRequestStorage()
        let directoryService = DirectoryService.shared
        
        let paymentRequestService = PaymentRequestService(
            paykitClient: paykitClient,
            autopayEvaluator: autoPayViewModel,
            paymentRequestStorage: paymentRequestStorage,
            directoryService: directoryService
        )
        
        // Handle the payment request
        paymentRequestService.handleIncomingRequest(requestId: requestId, fromPubkey: fromPubkey) { result in
            Task { @MainActor in
                switch result {
                case .success(let processingResult):
                    switch processingResult {
                    case .autoPaid(let paymentResult):
                        app.toast(type: .success, title: "Payment Completed", description: "Payment was automatically processed")
                        Logger.info("Auto-paid payment request \(requestId)", context: "MainNavView")
                    case .needsApproval(let request):
                        app.toast(type: .info, title: "Payment Request", description: "Amount: \(request.amountSats) sats from \(fromPubkey.prefix(12))...")
                        // TODO: Show payment approval UI
                    case .denied(let reason):
                        app.toast(type: .warning, title: "Payment Denied", description: reason)
                    case .error(let error):
                        app.toast(type: .error, title: "Payment Error", description: error.localizedDescription)
                    }
                case .failure(let error):
                    Logger.error("Payment request handling failed: \(error)", context: "MainNavView")
                    app.toast(type: .error, title: "Request Failed", description: error.localizedDescription)
                }
            }
        }
    }
}
