//
//  ProfileEditView.swift
//  Bitkit
//
//  Edit and publish profile to Pubky directory
//

import SwiftUI
import PhotosUI

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showDisconnectAlert = false
    
    // Profile fields
    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var links: [EditableLink] = []
    @State private var avatarUrl: String?
    @State private var selectedImage: UIImage?
    @State private var selectedPhotoItem: PhotosPickerItem?
    
    // Original profile for comparison
    @State private var originalProfile: PubkyProfile?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Edit Profile",
                action: AnyView(
                    HStack(spacing: 16) {
                        Button {
                            Task { await loadCurrentProfile(forceRefresh: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(isLoading ? .textSecondary : .white)
                        }
                        .disabled(isLoading)
                        
                        if hasChanges {
                            Button("Save") {
                                Task { await saveProfile() }
                            }
                            .foregroundColor(.brandAccent)
                        }
                    }
                ),
                onBack: { dismiss() }
            )
            
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    BodyMText("Loading profile...")
                        .foregroundColor(.textSecondary)
                        .padding(.top, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        // Profile Avatar
                        profileAvatarSection
                        
                        // Name field
                        VStack(alignment: .leading, spacing: 8) {
                            BodySText("Display Name")
                                .foregroundColor(.textSecondary)
                            
                        TextField("Enter your name", text: $name)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .accessibilityIdentifier("Display Name")
                        }
                        .padding(.horizontal, 16)
                        
                        // Bio field
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                BodySText("Bio")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                Text("\(bio.count)/160").font(Fonts.regular(size: 11))
                                    .foregroundColor(bio.count > 160 ? .red : .textSecondary)
                            }
                            
                            TextEditor(text: $bio)
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                        }
                        .padding(.horizontal, 16)
                        
                        // Links section
                        linksSection
                        
                        // Error/Success messages
                        if let error = errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.redAccent)
                                BodySText(error)
                                    .foregroundColor(.redAccent)
                            }
                            .padding(.horizontal, 16)
                        }
                        
                        if let success = successMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.greenAccent)
                                BodySText(success)
                                    .foregroundColor(.greenAccent)
                                    .accessibilityIdentifier("Profile published successfully")
                            }
                            .padding(.horizontal, 16)
                        }
                        
                        // Preview section
                        if hasChanges {
                            previewSection
                        }
                        
                        // Save button
                        Button {
                            Task { await saveProfile() }
                        } label: {
                            HStack {
                                if isSaving {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                }
                                Text("Publish to Pubky")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(hasChanges ? Color.brandAccent : Color.gray6)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(!hasChanges || isSaving)
                        .padding(.horizontal, 16)
                        
                        // Disconnect section
                        disconnectSection
                        
                        Spacer(minLength: 32)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .background(Color.customBlack)
        .onAppear {
            Task {
                await loadCurrentProfile()
            }
        }
        .alert("Disconnect from Pubky", isPresented: $showDisconnectAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                performDisconnect()
            }
        } message: {
            Text("This will clear your profile and session data. You'll need to reconnect with Pubky Ring to use Paykit features again.")
        }
    }
    
    // MARK: - Subviews
    
    private var profileAvatarSection: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        Circle()
                            .fill(Color.brandAccent.opacity(0.2))
                            .frame(width: 100, height: 100)
                            .overlay {
                                if let image = selectedImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(Circle())
                                } else if !name.isEmpty {
                                    Text(String(name.prefix(1)).uppercased())
                                        .font(Fonts.bold(size: 34))
                                        .foregroundColor(.brandAccent)
                                } else {
                                    Image(systemName: "person.fill")
                                        .font(Fonts.bold(size: 34))
                                        .foregroundColor(.brandAccent)
                                }
                            }
                            .clipShape(Circle())
                        
                        Circle()
                            .fill(Color.brandAccent)
                            .frame(width: 32, height: 32)
                            .overlay {
                                Image(systemName: "camera.fill")
                                    .font(Fonts.regular(size: 13))
                                    .foregroundColor(.white)
                            }
                    }
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data) {
                            await MainActor.run {
                                selectedImage = uiImage
                            }
                        }
                    }
                }
                
                Text("Tap to change photo")
                    .font(Fonts.regular(size: 13))
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
    }
    
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodySText("Links")
                    .foregroundColor(.textSecondary)
                Spacer()
                Button {
                    links.append(EditableLink(title: "", url: ""))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Link")
                    }
                    .font(Fonts.regular(size: 13))
                    .foregroundColor(.brandAccent)
                }
            }
            
            ForEach(links.indices, id: \.self) { index in
                VStack(spacing: 8) {
                    HStack {
                        TextField("Title", text: $links[index].title)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(Color.gray6)
                            .cornerRadius(6)
                            .foregroundColor(.white)
                        
                        Button {
                            links.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.redAccent)
                        }
                    }
                    
                    TextField("URL", text: $links[index].url)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.gray6)
                        .cornerRadius(6)
                        .foregroundColor(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)
                .background(Color.gray7)
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
    }
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodySText("Preview")
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 16)
            
            ProfilePreviewCard(profile: currentProfile, selectedImage: selectedImage)
                .padding(.horizontal, 16)
        }
    }
    
    private var disconnectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .background(Color.gray5)
                .padding(.horizontal, 16)
                .padding(.top, 24)
            
            VStack(alignment: .leading, spacing: 8) {
                BodySText("Connection")
                    .foregroundColor(.textSecondary)
                
                if let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() {
                    BodySText("Connected: \(String(pubkey.prefix(16)))...")
                        .foregroundColor(.textSecondary)
                        .font(Fonts.regular(size: 13))
                }
            }
            .padding(.horizontal, 16)
            
            Button {
                showDisconnectAlert = true
            } label: {
                HStack {
                    Image(systemName: "link.badge.xmark")
                    Text("Disconnect from Pubky")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.gray6)
                .foregroundColor(.redAccent)
                .cornerRadius(8)
            }
            .padding(.horizontal, 16)
        }
    }
    
    private func performDisconnect() {
        PaykitManager.shared.disconnect()
        dismiss()
    }
    
    // MARK: - Computed Properties
    
    private var currentProfile: PubkyProfile {
        // Note: For production, you'd upload the selected image and get back a URL
        // For now, we preserve the existing avatar URL
        PubkyProfile(
            name: name.isEmpty ? nil : name,
            bio: bio.isEmpty ? nil : bio,
            avatar: avatarUrl,
            links: links.isEmpty ? nil : links.filter { !$0.title.isEmpty && !$0.url.isEmpty }.map {
                PubkyProfileLink(title: $0.title, url: $0.url)
            }
        )
    }
    
    private var hasChanges: Bool {
        // If a new image was selected, there are changes
        if selectedImage != nil {
            return true
        }
        
        guard let original = originalProfile else {
            return !name.isEmpty || !bio.isEmpty || !links.isEmpty
        }
        
        let currentLinks = links.filter { !$0.title.isEmpty && !$0.url.isEmpty }
        let originalLinks = original.links ?? []
        
        return name != (original.name ?? "") ||
               bio != (original.bio ?? "") ||
               currentLinks.count != originalLinks.count
    }
    
    // MARK: - Actions
    
    private func loadCurrentProfile(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        
        guard let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            await MainActor.run {
                self.isLoading = false
            }
            return
        }
        
        do {
            // If force refresh, fetch directly from network; otherwise use cache
            let profile: PubkyProfile?
            if forceRefresh {
                profile = try await DirectoryService.shared.fetchProfile(for: pubkey)
            } else {
                profile = try await DirectoryService.shared.getOrFetchProfile(pubkey: pubkey)
            }
            
            if let profile = profile {
                await MainActor.run {
                    self.originalProfile = profile
                    self.name = profile.name ?? ""
                    self.bio = profile.bio ?? ""
                    self.avatarUrl = profile.avatar
                    self.links = profile.links?.map {
                        EditableLink(title: $0.title, url: $0.url)
                    } ?? []
                    // Clear selected image on refresh to show current server state
                    if forceRefresh {
                        self.selectedImage = nil
                        self.selectedPhotoItem = nil
                    }
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load profile: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func saveProfile() async {
        isSaving = true
        errorMessage = nil
        successMessage = nil
        
        do {
            // Upload image if user selected a new one
            var imageUrl = avatarUrl
            if let image = selectedImage {
                guard let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
                    throw ImageUploadError.notAuthenticated
                }
                imageUrl = try await ImageUploadService.shared.uploadProfileImage(image, ownerPubkey: pubkey)
            }
            
            // Build profile with the (potentially new) image URL
            let profileToPublish = PubkyProfile(
                name: name.isEmpty ? nil : name,
                bio: bio.isEmpty ? nil : bio,
                avatar: imageUrl,
                links: links.isEmpty ? nil : links.filter { !$0.title.isEmpty && !$0.url.isEmpty }.map {
                    PubkyProfileLink(title: $0.title, url: $0.url)
                }
            )
            
            try await DirectoryService.shared.publishProfile(profileToPublish)
            await MainActor.run {
                self.avatarUrl = imageUrl
                self.selectedImage = nil  // Clear local image since it's now on server
                self.originalProfile = profileToPublish
                self.successMessage = "Profile published successfully!"
                self.isSaving = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to publish: \(error.localizedDescription)"
                self.isSaving = false
            }
        }
    }
}

// MARK: - Supporting Types

struct EditableLink: Identifiable {
    let id = UUID()
    var title: String
    var url: String
}

// MARK: - Preview

#Preview {
    ProfileEditView()
}

