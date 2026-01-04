import PhotosUI
import SwiftUI

struct SendOptionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var scanner: ScannerManager
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var sheets: SheetViewModel

    @Binding var navigationPath: [SendRoute]
    @State private var selectedItem: PhotosPickerItem?
    @State private var showingContactPicker = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__send_bitcoin"))

            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 8) {
                    Scanner(
                        onScan: { uri in
                            await scanner.handleSendScan(uri) { route in
                                if let route {
                                    navigationPath.append(route)
                                }
                            }
                        },
                        onImageSelection: { item in
                            await scanner.handleImageSelection(item, context: .send) { route in
                                if let route {
                                    navigationPath.append(route)
                                }
                            }
                        }
                    )

                    RectangleButton(
                        icon: "users",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_contact"),
                        testID: "RecipientContact"
                    ) {
                        handleContact()
                    }

                    RectangleButton(
                        icon: "clipboard",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_invoice"),
                        testID: "RecipientInvoice"
                    ) {
                        handlePaste()
                    }

                    RectangleButton(
                        icon: "pencil",
                        iconColor: .brandAccent,
                        title: t("wallet__recipient_manual"),
                        testID: "RecipientManual"
                    ) {
                        navigationPath.append(.manual)
                    }
                }
            }
        }
        .sheetBackground()
        .padding(.horizontal, 16)
        .onAppear {
            wallet.syncState()
            scanner.configure(
                app: app,
                currency: currency,
                settings: settings
            )
        }
        .sheet(isPresented: $showingContactPicker) {
            ContactPickerSheet(
                onSelect: { contact in
                    sheets.hideSheet()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NoisePaymentPrefill.shared.recipientPubkey = contact.publicKeyZ32
                        navigation.navigate(.paykitNoisePayment)
                    }
                },
                onNavigateToDiscovery: {
                    sheets.hideSheet()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        navigation.navigate(.paykitContactDiscovery)
                    }
                }
            )
        }
    }

    func handlePaste() {
        guard let uri = UIPasteboard.general.string else {
            app.toast(
                type: .warning,
                title: t("wallet__send_clipboard_empty_title"),
                description: t("wallet__send_clipboard_empty_text")
            )
            return
        }

        Task {
            await scanner.handleSendScan(uri) { route in
                if let route {
                    navigationPath.append(route)
                }
            }
        }
    }

    func handleContact() {
        showingContactPicker = true
    }
}

/// Shared prefill storage for noise payment navigation
class NoisePaymentPrefill {
    static let shared = NoisePaymentPrefill()
    var recipientPubkey: String?
    
    private init() {}
    
    func consume() -> String? {
        let value = recipientPubkey
        recipientPubkey = nil
        return value
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendOptionsView(navigationPath: .constant([]))
                        .environmentObject(AppViewModel())
                        .environmentObject(CurrencyViewModel())
                        .environmentObject(NavigationViewModel())
                        .environmentObject(ScannerManager())
                        .environmentObject(SettingsViewModel.shared)
                        .environmentObject(WalletViewModel())
                        .environmentObject(SheetViewModel())
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
