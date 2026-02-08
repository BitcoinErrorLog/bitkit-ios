import SwiftUI

struct Header: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    @State private var profileName: String?
    @State private var avatarImage: UIImage?

    private let keyManager = PaykitKeyManager.shared
    private let profileStorage = ProfileStorage.shared

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                if app.hasSeenProfileIntro {
                    navigation.navigate(.profile)
                } else {
                    navigation.navigate(.profileIntro)
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    if let name = profileName, !name.isEmpty {
                        ZStack {
                            Circle()
                                .fill(Color.brand24)
                                .frame(width: 32, height: 32)

                            if let avatar = avatarImage {
                                Image(uiImage: avatar)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)
                                    .clipShape(Circle())
                            } else {
                                Text(name.prefix(1).uppercased())
                                    .font(Fonts.bold(size: 14))
                                    .foregroundColor(.brandAccent)
                            }
                        }

                        Text(name)
                            .font(Fonts.semiBold(size: 17))
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                    } else {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                            .foregroundColor(.gray1)
                            .frame(width: 32, height: 32)

                        Text("Your Name")
                            .font(Fonts.semiBold(size: 17))
                            .foregroundColor(.white64)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("ProfileHeader")

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
                        .padding(.leading, 16)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("HeaderMenu")
            }
        }
        .frame(height: 48)
        .zIndex(.infinity)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .task {
            loadProfile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .profileDidUpdate)) { _ in
            loadProfile()
        }
    }

    private func loadProfile() {
        guard let pubkey = keyManager.getCurrentPublicKeyZ32(),
              let profile = profileStorage.getProfile(for: pubkey) else {
            profileName = nil
            avatarImage = nil
            return
        }
        profileName = profile.name
        
        if let imageUrl = profile.image, !imageUrl.isEmpty {
            Task {
                let downloaded = await ImageUploadService.shared.downloadProfileImage(fileUrl: imageUrl)
                await MainActor.run {
                    self.avatarImage = downloaded
                }
            }
        } else {
            avatarImage = nil
        }
    }
}

extension Notification.Name {
    static let profileDidUpdate = Notification.Name("profileDidUpdate")
}
