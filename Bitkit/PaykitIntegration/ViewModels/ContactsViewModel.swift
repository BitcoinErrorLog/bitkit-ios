//
//  ContactsViewModel.swift
//  Bitkit
//
//  ViewModel for Contacts management.
//  Contacts are synchronized with Pubky follows - the homeserver is the source of truth.
//

import Foundation
import SwiftUI

@MainActor
class ContactsViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var searchQuery: String = ""
    @Published var isLoading = false
    @Published var showingAddContact = false
    @Published var showingDiscovery = false
    @Published var discoveredContacts: [DirectoryDiscoveredContact] = []
    @Published var showingDiscoveryResults = false
    @Published var errorMessage: String?
    
    /// Unfiltered list of all contacts (used for searching)
    private var allContacts: [Contact] = []
    
    private let contactStorage: ContactStorage
    private let directoryService: DirectoryService
    private let identityName: String
    
    init(identityName: String = "default", directoryService: DirectoryService = .shared) {
        self.identityName = identityName
        self.contactStorage = ContactStorage(identityName: identityName)
        self.directoryService = directoryService
    }
    
    /// Load contacts by syncing from Pubky follows and merging with local storage
    func loadContacts() {
        isLoading = true
        
        Task {
            do {
                // Sync contacts from Pubky follows (source of truth)
                let follows = try await directoryService.discoverContactsFromFollows()
                
                // Convert discovered contacts to Contact model and merge with local data
                var followContacts: [Contact] = []
                for discovered in follows {
                    let existing = contactStorage.getContact(id: discovered.pubkey)
                    let contact = Contact(
                        publicKeyZ32: discovered.pubkey,
                        name: discovered.name ?? existing?.name ?? "",
                        notes: existing?.notes,
                        avatarUrl: discovered.avatarUrl ?? existing?.avatarUrl
                    )
                    // Preserve payment history from existing
                    var mutableContact = contact
                    if let existing = existing {
                        mutableContact.lastPaymentAt = existing.lastPaymentAt
                        mutableContact.paymentCount = existing.paymentCount
                    }
                    followContacts.append(mutableContact)
                }
                
                // Persist synced contacts locally for offline access
                try contactStorage.importContacts(followContacts)
                
                // Update UI state
                await MainActor.run {
                    self.discoveredContacts = follows
                    self.allContacts = followContacts
                    if self.searchQuery.isEmpty {
                        self.contacts = followContacts
                    } else {
                        self.contacts = followContacts.filter { contact in
                            contact.name.localizedCaseInsensitiveContains(self.searchQuery) ||
                            contact.publicKeyZ32.localizedCaseInsensitiveContains(self.searchQuery)
                        }
                    }
                    self.isLoading = false
                }
                
                Logger.debug("Loaded \(followContacts.count) contacts from Pubky follows", context: "ContactsViewModel")
            } catch {
                Logger.error("Failed to load contacts from follows: \(error)", context: "ContactsViewModel")
                // Fallback to local storage
                await MainActor.run {
                    let localContacts = self.contactStorage.listContacts()
                    self.allContacts = localContacts
                    self.contacts = localContacts
                    self.isLoading = false
                }
            }
        }
    }
    
    func searchContacts() {
        if searchQuery.isEmpty {
            // Show all contacts when search is cleared
            contacts = allContacts.isEmpty ? contactStorage.listContacts() : allContacts
        } else {
            // Filter from the unfiltered list
            let source = allContacts.isEmpty ? contactStorage.listContacts() : allContacts
            let query = searchQuery.lowercased()
            contacts = source.filter { contact in
                contact.name.lowercased().contains(query) ||
                contact.publicKeyZ32.lowercased().contains(query)
            }
        }
    }
    
    /// Add a contact - creates a Pubky follow first, then saves locally
    func addContact(_ contact: Contact) throws {
        // Save locally first for immediate feedback
        try contactStorage.saveContact(contact)
        loadContacts()
        
        // Then create Pubky follow in background
        Task {
            do {
                try await directoryService.addFollow(pubkey: contact.publicKeyZ32)
                Logger.info("Added follow for contact: \(contact.publicKeyZ32.prefix(12))...", context: "ContactsViewModel")
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to sync follow to Pubky: \(error.localizedDescription)"
                }
                Logger.error("Failed to add follow: \(error)", context: "ContactsViewModel")
            }
        }
    }
    
    func updateContact(_ contact: Contact) throws {
        try contactStorage.saveContact(contact)
        loadContacts()
    }
    
    /// Delete a contact - removes locally first, then removes Pubky follow
    func deleteContact(_ contact: Contact) throws {
        // Delete locally first for immediate feedback
        try contactStorage.deleteContact(id: contact.id)
        loadContacts()
        
        // Then remove Pubky follow in background
        Task {
            do {
                try await directoryService.removeFollow(pubkey: contact.publicKeyZ32)
                Logger.info("Removed follow for contact: \(contact.publicKeyZ32.prefix(12))...", context: "ContactsViewModel")
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to sync unfollow to Pubky: \(error.localizedDescription)"
                }
                Logger.error("Failed to remove follow: \(error)", context: "ContactsViewModel")
            }
        }
    }
    
    /// Follow a pubkey on Pubky and add to contacts
    func followContact(pubkey: String) async {
        do {
            try await directoryService.addFollow(pubkey: pubkey)
            
            // Refresh contacts to show the new follow
            loadContacts()
        } catch {
            errorMessage = "Failed to follow: \(error.localizedDescription)"
            Logger.error("Failed to follow \(pubkey.prefix(12))...: \(error)", context: "ContactsViewModel")
        }
    }
    
    /// Unfollow a pubkey on Pubky and remove from contacts
    func unfollowContact(pubkey: String) async {
        do {
            try await directoryService.removeFollow(pubkey: pubkey)
            
            // Also remove from local storage
            try? contactStorage.deleteContact(id: pubkey)
            
            // Refresh contacts
            loadContacts()
        } catch {
            errorMessage = "Failed to unfollow: \(error.localizedDescription)"
            Logger.error("Failed to unfollow \(pubkey.prefix(12))...: \(error)", context: "ContactsViewModel")
        }
    }
    
    func discoverContacts() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            discoveredContacts = try await directoryService.discoverContactsFromFollows()
            showingDiscoveryResults = true
        } catch {
            errorMessage = "Failed to discover contacts: \(error.localizedDescription)"
            Logger.error("Failed to discover contacts: \(error)", context: "ContactsViewModel")
        }
    }
    
    func importDiscovered(_ contacts: [Contact]) {
        do {
            try contactStorage.importContacts(contacts)
            loadContacts()
        } catch {
            Logger.error("Failed to import contacts: \(error)", context: "ContactsViewModel")
        }
    }
    
    func clearError() {
        errorMessage = nil
    }
}
