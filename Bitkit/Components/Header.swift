import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    
    @State private var profile: PubkyProfile?
    @State private var hasIdentity = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                if app.hasSeenProfileIntro {
                    navigation.navigate(.profile)
                } else {
                    navigation.navigate(.profileIntro)
                }
            } label: {
                HStack(alignment: .center, spacing: 16) {
                    profileAvatar
                    
                    TitleText(profile?.name ?? t("slashtags__your_name_capital"))
                }
            }
            .onAppear {
                loadProfile()
            }
            .onReceive(NotificationCenter.default.publisher(for: .profileUpdated)) { _ in
                loadProfile()
            }

            Spacer()

            HStack(alignment: .center, spacing: 12) {
                AppStatus(
                    testID: "HeaderAppStatus",
                    onPress: {
                        navigation.navigate(.appStatus)
                    }
                )

                Button {
                    withAnimation {
                        app.showDrawer = true
                    }
                } label: {
                    Image("burger")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .frame(width: 32, height: 32)
                }
                .accessibilityIdentifier("HeaderMenu")
            }
        }
        .frame(height: 48)
        .zIndex(.infinity)
        .padding(.leading, 16)
        .padding(.trailing, 10)
    }
    
    @ViewBuilder
    private var profileAvatar: some View {
        if let avatarUrl = profile?.avatar, let url = URL(string: avatarUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                default:
                    avatarFallback
                }
            }
        } else {
            avatarFallback
        }
    }
    
    @ViewBuilder
    private var avatarFallback: some View {
        if let name = profile?.name, !name.isEmpty {
            Circle()
                .fill(Color.brandAccent.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.brandAccent)
                }
        } else {
            Image(systemName: "person.circle.fill")
                .resizable()
                .font(.title2)
                .foregroundColor(.gray1)
                .frame(width: 32, height: 32)
        }
    }
    
    private func loadProfile() {
        // Check if we have an identity
        if let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() {
            hasIdentity = true
            // Load from local storage first (fast)
            profile = ProfileStorage.shared.getProfile(for: pubkey)
        } else {
            hasIdentity = false
            profile = nil
        }
    }
}
