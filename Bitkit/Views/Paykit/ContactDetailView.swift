//
//  ContactDetailView.swift
//  Bitkit
//
//  Contact detail view with profile and unfollow option
//

import SwiftUI

struct ContactDetailView: View {
    let contactId: String
    @ObservedObject var viewModel: ContactsViewModel
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false
    
    private var contact: Contact? {
        viewModel.contacts.first { $0.id == contactId }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: "Contact")
            
            if let contact = contact {
                ContactDetailContent(
                    contact: contact,
                    isDeleting: isDeleting,
                    onCopyPubkey: {
                        UIPasteboard.general.string = contact.publicKeyZ32
                        app.toast(type: .success, title: "Copied", description: "Public key copied to clipboard")
                    },
                    onSendPayment: {
                        NoisePaymentPrefill.shared.recipientPubkey = contact.publicKeyZ32
                        navigation.navigate(.paykitNoisePayment)
                    },
                    onRemoveContact: {
                        showingDeleteConfirm = true
                    }
                )
            } else {
                VStack {
                    Spacer()
                    ProgressView()
                        .tint(.brandAccent)
                    Spacer()
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            if contact == nil {
                viewModel.loadContacts()
            }
        }
        .alert("Remove Contact", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if let contact = contact {
                    isDeleting = true
                    do {
                        try viewModel.deleteContact(contact)
                        navigation.navigateBack()
                    } catch {
                        app.toast(type: .error, title: "Error", description: error.localizedDescription)
                        isDeleting = false
                    }
                }
            }
        } message: {
            Text("This will unfollow \(contact?.name.isEmpty == false ? contact!.name : "this contact") on your homeserver. Are you sure?")
        }
    }
}

private struct ContactDetailContent: View {
    let contact: Contact
    let isDeleting: Bool
    let onCopyPubkey: () -> Void
    let onSendPayment: () -> Void
    let onRemoveContact: () -> Void
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Large Avatar
                Circle()
                    .fill(Color.brandAccent.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .overlay {
                        Text(String(contact.name.isEmpty ? contact.publicKeyZ32.prefix(1) : contact.name.prefix(1)).uppercased())
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.brandAccent)
                    }
                
                // Name
                Text(contact.name.isEmpty ? "Unknown Contact" : contact.name)
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                // Public Key Card
                VStack(alignment: .leading, spacing: 8) {
                    BodySText("PUBLIC KEY")
                        .foregroundColor(.textSecondary)
                    
                    HStack {
                        Text(contact.publicKeyZ32)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Spacer()
                        
                        Button(action: onCopyPubkey) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.brandAccent)
                        }
                    }
                }
                .padding(16)
                .background(Color.gray6)
                .cornerRadius(12)
                
                // Payment Stats
                if contact.paymentCount > 0 || contact.lastPaymentAt != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        BodySText("PAYMENT HISTORY")
                            .foregroundColor(.textSecondary)
                        
                        if contact.paymentCount > 0 {
                            HStack {
                                BodyMText("Total Payments")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                BodyMText("\(contact.paymentCount)")
                                    .foregroundColor(.greenAccent)
                            }
                        }
                        
                        if let lastPayment = contact.lastPaymentAt {
                            HStack {
                                BodyMText("Last Payment")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                BodyMText(formatDate(lastPayment))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color.gray6)
                    .cornerRadius(12)
                }
                
                // Notes
                if let notes = contact.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        BodySText("NOTES")
                            .foregroundColor(.textSecondary)
                        
                        BodyMText(notes)
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.gray6)
                    .cornerRadius(12)
                }
                
                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: onSendPayment) {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text("Send Payment")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.brandAccent)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .font(.headline)
                    }
                    
                    Button(action: onRemoveContact) {
                        HStack {
                            if isDeleting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "person.badge.minus")
                                Text("Remove Contact")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.gray6)
                        .foregroundColor(.redAccent)
                        .cornerRadius(12)
                        .font(.headline)
                    }
                    .disabled(isDeleting)
                }
                
                BodySText("Removing this contact will unfollow them on your Pubky homeserver")
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

