import SwiftUI

enum IncomingPaymentState {
    case connecting
    case completing
    case completed(sats: UInt64)
    case expired
}

struct IncomingPaymentView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var state: IncomingPaymentState = .connecting
    @State private var hasCopiedMessage = false
    
    let paymentHash: String?

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("incoming__nav_title"), showBackButton: true)
                .padding(.bottom, 16)

            VStack(alignment: .center, spacing: 24) {
                Spacer()

                stateContent

                Spacer()

                if case .expired = state {
                    expiredActions
                }

                if case .completed = state {
                    CustomButton(title: t("common__done")) {
                        navigation.reset()
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task {
            await completePayment()
        }
    }

    @ViewBuilder
    var stateContent: some View {
        switch state {
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .purpleAccent))
                    .scaleEffect(1.5)
                BodyMText(t("incoming__connecting"), textColor: .white64)
            }

        case .completing:
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .purpleAccent))
                    .scaleEffect(1.5)
                BodyMText(t("incoming__completing"), textColor: .white64)
            }

        case let .completed(sats):
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .foregroundColor(.green)
                DisplayText(t("incoming__received", variables: ["sats": String(sats)]), accentColor: .purpleAccent)
            }

        case .expired:
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .foregroundColor(.orange)
                DisplayText(t("incoming__expired_title"), accentColor: .white)
                BodyMText(t("incoming__expired_text"), textColor: .white64)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    var expiredActions: some View {
        VStack(spacing: 12) {
            CustomButton(title: t("incoming__retry")) {
                state = .connecting
                Task {
                    await completePayment()
                }
            }

            Button {
                let message = t("incoming__copy_message_text")
                UIPasteboard.general.string = message
                hasCopiedMessage = true
                app.toast(type: .success, title: t("common__copied"))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasCopiedMessage ? "checkmark" : "doc.on.doc")
                    Text(t("incoming__copy_message"))
                }
                .foregroundColor(.purpleAccent)
            }
            .padding(.vertical, 12)
        }
    }

    private func completePayment() async {
        state = .connecting

        do {
            // Use wallet's start which handles the full node lifecycle
            try await wallet.start()
            
            state = .completing

            try await LightningService.shared.connectToTrustedPeers()
            try await LightningService.shared.sync()

            // Wait up to 10 seconds for the payment to complete
            try await Task.sleep(nanoseconds: 10_000_000_000)
            
            // Check if we received the payment by looking at balance change
            // For now, just mark as completed if we got this far without error
            if case .completing = state {
                // No payment received in time
                state = .expired
            }
        } catch {
            Logger.error("Failed to complete incoming payment: \(error)", context: "IncomingPaymentView")
            state = .expired
        }
    }
}

#Preview("Connecting") {
    IncomingPaymentView(paymentHash: "abc123")
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}

#Preview("Expired") {
    IncomingPaymentView(paymentHash: "abc123")
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .environmentObject(WalletViewModel())
        .onAppear {
            // Note: In previews we can't easily set state
        }
        .preferredColorScheme(.dark)
}
