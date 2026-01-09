import LDKNode
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
    @State private var timeoutTask: Task<Void, Never>?

    private let eventHandlerId = "IncomingPaymentView-\(UUID().uuidString)"
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
        .onDisappear {
            wallet.removeOnEvent(id: eventHandlerId)
            timeoutTask?.cancel()
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

        wallet.addOnEvent(id: eventHandlerId) { event in
            handleLightningEvent(event)
        }

        do {
            try await wallet.start()

            state = .completing

            try await LightningService.shared.connectToTrustedPeers()
            try await LightningService.shared.sync()

            timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    if case .completing = state {
                        state = .expired
                    }
                } catch {
                    // Task was cancelled, which is expected on success
                }
            }
        } catch {
            Logger.error("Failed to complete incoming payment: \(error)", context: "IncomingPaymentView")
            state = .expired
        }
    }

    private func handleLightningEvent(_ event: Event) {
        switch event {
        case let .paymentReceived(paymentId, eventPaymentHash, amountMsat, _):
            let receivedHash = paymentId ?? eventPaymentHash
            if let expectedHash = paymentHash, !expectedHash.isEmpty {
                if receivedHash == expectedHash {
                    timeoutTask?.cancel()
                    state = .completed(sats: amountMsat / 1000)
                    Logger.info("Matched incoming payment: \(receivedHash)", context: "IncomingPaymentView")
                }
            } else {
                timeoutTask?.cancel()
                state = .completed(sats: amountMsat / 1000)
                Logger.info("Received payment (no hash filter): \(receivedHash)", context: "IncomingPaymentView")
            }
        default:
            break
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
