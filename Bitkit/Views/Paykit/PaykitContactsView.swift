//
//  PaykitContactsView.swift
//  Bitkit
//
//  Contact list and management view
//

import SwiftUI

struct PaykitContactsView: View {
    @StateObject private var viewModel = ContactsViewModel()
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @State private var showingAddContact = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Contacts",
                action: AnyView(
                    HStack(spacing: 16) {
                        Button {
                            viewModel.loadContacts()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.brandAccent)
                        }
                        .accessibilityIdentifier("RefreshContacts")
                        
                        Button {
                            showingAddContact = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(.brandAccent)
                        }
                        .accessibilityIdentifier("AddContact")
                        
                        Button {
                            navigation.navigate(.paykitContactDiscovery)
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .foregroundColor(.brandAccent)
                        }
                        .accessibilityIdentifier("DiscoverContacts")
                    }
                )
            )
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.textSecondary)
                        
                        TextField("Search contacts", text: $viewModel.searchQuery)
                            .foregroundColor(.white)
                            .onChange(of: viewModel.searchQuery) { _ in
                                viewModel.searchContacts()
                            }
                    }
                    .padding(12)
                    .background(Color.gray6)
                    .cornerRadius(8)
                    
                    // Loading indicator
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .tint(.brandAccent)
                            Spacer()
                        }
                        .padding(.vertical, 32)
                    } else if viewModel.contacts.isEmpty {
                        // Empty state
                        VStack(spacing: 16) {
                            Image(systemName: "person.2.slash")
                                .font(Fonts.regular(size: 48))
                                .foregroundColor(.textSecondary)
                            
                            BodyMText("No contacts")
                                .foregroundColor(.textSecondary)
                            
                            Button {
                                navigation.navigate(.paykitContactDiscovery)
                            } label: {
                                HStack {
                                    Image(systemName: "person.badge.plus")
                                    Text("Add a follow on Pubky")
                                }
                                .foregroundColor(.brandAccent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // Contact list
                        VStack(spacing: 0) {
                            ForEach(viewModel.contacts) { contact in
                                Button {
                                    navigation.navigate(.paykitContactDetail(contact.id))
                                } label: {
                                    ContactRow(contact: contact)
                                }
                                .buttonStyle(.plain)
                                
                                if contact.id != viewModel.contacts.last?.id {
                                    Divider()
                                        .background(Color.white16)
                                }
                            }
                        }
                        .background(Color.gray6)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .task {
            viewModel.loadContacts()
        }
        .sheet(isPresented: $showingAddContact) {
            AddContactView(viewModel: viewModel)
        }
        .onChange(of: viewModel.errorMessage) { error in
            if let error = error {
                app.toast(type: .error, title: "Sync Error", description: error)
                viewModel.clearError()
            }
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    
    var body: some View {
        HStack {
            Circle()
                .fill(Color.brandAccent.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String(contact.name.isEmpty ? contact.publicKeyZ32.prefix(1) : contact.name.prefix(1)).uppercased())
                        .foregroundColor(.brandAccent)
                        .font(Fonts.semiBold(size: 17))
                }
            
            VStack(alignment: .leading, spacing: 4) {
                BodyMText(contact.name.isEmpty ? "Unknown" : contact.name)
                    .foregroundColor(.white)
                
                BodySText(contact.abbreviatedKey)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            if contact.paymentCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    BodySText("\(contact.paymentCount) payment\(contact.paymentCount == 1 ? "" : "s")")
                        .foregroundColor(.textSecondary)
                    
                    if let lastPayment = contact.lastPaymentAt {
                        BodySText(formatDate(lastPayment))
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
        .padding(16)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct AddContactView: View {
    @ObservedObject var viewModel: ContactsViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var publicKey = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Contact Information") {
                    TextField("Name", text: $name)
                    TextField("Public Key (z-base32)", text: $publicKey)
                        .autocapitalization(.none)
                    TextField("Notes (optional)", text: $notes)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let contact = Contact(
                            publicKeyZ32: publicKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            notes: notes.isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        do {
                            try viewModel.addContact(contact)
                            dismiss()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(name.isEmpty || publicKey.isEmpty)
                }
            }
        }
    }
}
