//
//  ProfileView.swift
//  Bitkit
//
//  Combined profile view that shows connection options if not connected,
//  or profile editor if connected. Similar to Android's CreateProfileScreen.
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @State private var isLoading = true
    @State private var hasIdentity = false
    @State private var showPubkyRingAuth = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    
    private let pubkyRingBridge = PubkyRingBridge.shared
    private let keyManager = PaykitKeyManager.shared  // Used for identity check
    
    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if hasIdentity {
                ProfileEditView()
            } else {
                noIdentityView
            }
        }
        .onAppear {
            checkIdentity()
        }
        .sheet(isPresented: $showPubkyRingAuth) {
            PubkyRingAuthView { session in
                handleSessionReceived(session)
            }
        }
    }
    
    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Profile")
            
            Spacer()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                BodyMText("Loading...")
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
        .navigationBarHidden(true)
    }
    
    private var noIdentityView: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("slashtags__profile_create"))
            
            ScrollView {
                VStack(spacing: 32) {
                    Spacer().frame(height: 40)
                    
                    ZStack {
                        Circle()
                            .fill(Color.brandAccent.opacity(0.1))
                            .frame(width: 100, height: 100)
                        
                        Image(systemName: "person.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.brandAccent)
                    }
                    
                    VStack(spacing: 16) {
                        HeadlineText("Set Up Your Profile")
                            .foregroundColor(.white)
                        
                        BodyMText("Create a public profile so others can find and pay you. Your profile is published to your Pubky homeserver.")
                            .foregroundColor(.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            BodySText(error)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // Connect with Pubky Ring button
                    Button {
                        connectWithPubkyRing()
                    } label: {
                        HStack {
                            if isConnecting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .frame(width: 20, height: 20)
                                Text("Connecting...")
                                    .fontWeight(.semibold)
                            } else {
                                Image(systemName: "person.fill")
                                    .font(.title3)
                                Text("Connect with Pubky Ring")
                                    .fontWeight(.semibold)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.brandAccent)
                        .cornerRadius(12)
                    }
                    .disabled(isConnecting)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("ConnectPubkyRing")
                    
                    BodySText("Pubky-ring securely manages your identity across devices")
                        .foregroundColor(.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    Spacer()
                }
            }
        }
        .navigationBarHidden(true)
    }
    
    private func checkIdentity() {
        isLoading = true
        Task {
            // Check if we have a valid identity/session
            let pubkey = keyManager.getCurrentPublicKeyZ32()
            await MainActor.run {
                hasIdentity = pubkey != nil
                isLoading = false
            }
        }
    }
    
    private func connectWithPubkyRing() {
        if pubkyRingBridge.isPubkyRingInstalled {
            isConnecting = true
            errorMessage = nil
            
            Task {
                do {
                    let session = try await pubkyRingBridge.requestSession()
                    await MainActor.run {
                        handleSessionReceived(session)
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "Connection failed: \(error.localizedDescription)"
                        isConnecting = false
                    }
                }
            }
        } else {
            showPubkyRingAuth = true
        }
    }
    
    private func handleSessionReceived(_ session: PubkyRingSession) {
        PaykitManager.shared.setSession(session)
        hasIdentity = true
        isConnecting = false
        showPubkyRingAuth = false
        NotificationCenter.default.post(name: .profileDidUpdate, object: nil)
    }
}

#Preview {
    ProfileView()
        .environmentObject(AppViewModel())
        .environmentObject(NavigationViewModel())
        .preferredColorScheme(.dark)
}

