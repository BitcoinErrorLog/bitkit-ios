//
//  PaykitPaymentRequestsView.swift
//  Bitkit
//
//  Payment requests management view with full functionality
//

import SwiftUI

struct PaykitPaymentRequestsView: View {
    @StateObject private var viewModel = PaymentRequestsViewModel()
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @State private var showingCreateRequest = false
    @State private var selectedFilter: RequestFilter = .all
    @State private var selectedStatusFilter: PaymentRequestStatus? = nil
    @State private var peerFilter: String = ""
    @State private var showingFilters = false
    @State private var selectedRequest: BitkitPaymentRequest? = nil
    @State private var selectedSentRequest: SentPaymentRequest? = nil
    
    enum RequestFilter: String, CaseIterable {
        case all = "All"
        case incoming = "Incoming"
        case outgoing = "Outgoing"
        case pending = "Pending"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Payment Requests",
                action: AnyView(
                    HStack(spacing: 16) {
                        Button {
                            showingFilters.toggle()
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(hasActiveFilters ? .brandAccent : .textSecondary)
                        }
                        
                        Button {
                            showingCreateRequest = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(.brandAccent)
                        }
                    }
                )
            )
            
            // Tab Picker
            tabSection
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.selectedTab == .incoming {
                        // Discover button
                        VStack(alignment: .trailing, spacing: 8) {
                            Button {
                                Task {
                                    await viewModel.discoverRequests()
                                }
                            } label: {
                                HStack {
                                    if viewModel.isDiscovering {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text("Discover from Peers")
                                }
                                .foregroundColor(.brandAccent)
                            }
                            .disabled(viewModel.isDiscovering)
                            
                            if let result = viewModel.discoveryResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        
                        // Direction Filter Picker (for incoming tab)
                        filterSection
                        
                        // Advanced Filters
                        if showingFilters {
                            advancedFiltersSection
                        }
                        
                        // Requests List
                        if viewModel.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else if filteredRequests.isEmpty {
                            emptyStateView
                        } else {
                            requestsList
                        }
                    } else {
                        // Sent Tab
                        sentTabContent
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadRequests()
            viewModel.loadSentRequests()
            
            // Consume pending request ID from notification/deeplink
            if let requestId = app.pendingPaykitRequestId {
                app.pendingPaykitRequestId = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let request = viewModel.requests.first(where: { $0.id == requestId }) {
                        selectedRequest = request
                    }
                }
            }
        }
        .refreshable {
            await viewModel.discoverRequests()
            viewModel.loadRequests()
            viewModel.loadSentRequests()
        }
        .sheet(isPresented: $showingCreateRequest) {
            CreatePaymentRequestView(viewModel: viewModel)
        }
        .sheet(item: $selectedRequest) { request in
            PaymentRequestDetailSheet(request: request, viewModel: viewModel)
        }
        .sheet(item: $selectedSentRequest) { sentRequest in
            SentRequestDetailSheet(request: sentRequest, viewModel: viewModel)
        }
    }
    
    private var tabSection: some View {
        Picker("Tab", selection: $viewModel.selectedTab) {
            Text("Incoming").tag(PaymentRequestsViewModel.RequestTab.incoming)
            Text("Sent").tag(PaymentRequestsViewModel.RequestTab.sent)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    private var sentTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Cleanup orphaned requests button
            HStack {
                Spacer()
                Button {
                    Task {
                        _ = await viewModel.cleanupOrphanedRequests()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isCleaningUp {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "trash.circle")
                        }
                        BodySText("Cleanup Orphaned")
                    }
                    .foregroundColor(.brandAccent)
                }
                .disabled(viewModel.isCleaningUp)
            }
            
            if let cleanupResult = viewModel.cleanupResult {
                BodySText(cleanupResult)
                    .foregroundColor(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            
            if viewModel.sentRequests.isEmpty {
                sentEmptyStateView
            } else {
                sentRequestsList
            }
        }
    }
    
    private var sentEmptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "paperplane.circle")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Sent Requests")
                .foregroundColor(.textPrimary)
            
            BodyMText("Requests you send will appear here")
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var sentRequestsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.sentRequests) { request in
                SentRequestRow(
                    request: request,
                    onTap: {
                        selectedSentRequest = request
                    },
                    onCancel: {
                        Task {
                            await viewModel.cancelSentRequest(request)
                            app.toast(type: .success, title: "Request cancelled")
                        }
                    }
                )
                
                if request.id != viewModel.sentRequests.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray6)
        .cornerRadius(8)
    }
    
    private var hasActiveFilters: Bool {
        selectedStatusFilter != nil || !peerFilter.isEmpty
    }
    
    private var filterSection: some View {
        Picker("Filter", selection: $selectedFilter) {
            ForEach(RequestFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }
    
    private var advancedFiltersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMText("Advanced Filters")
                .foregroundColor(.textSecondary)
            
            // Status Filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    RequestFilterChip(title: "Any Status", isSelected: selectedStatusFilter == nil) {
                        selectedStatusFilter = nil
                    }
                    ForEach(PaymentRequestStatus.allCases, id: \.self) { status in
                        RequestFilterChip(title: status.rawValue, isSelected: selectedStatusFilter == status) {
                            selectedStatusFilter = status
                        }
                    }
                }
            }
            
            // Peer Filter
            HStack {
                Image(systemName: "person.circle")
                    .foregroundColor(.textSecondary)
                TextField("Filter by peer pubkey...", text: $peerFilter)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                if !peerFilter.isEmpty {
                    Button {
                        peerFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            .padding(12)
            .background(Color.gray6)
            .cornerRadius(8)
        }
        .padding(16)
        .background(Color.gray5)
        .cornerRadius(12)
    }
    
    private var filteredRequests: [BitkitPaymentRequest] {
        var results = viewModel.requests
        
        // Direction filter
        switch selectedFilter {
        case .all:
            break
        case .incoming:
            results = results.filter { $0.direction == .incoming }
        case .outgoing:
            results = results.filter { $0.direction == .outgoing }
        case .pending:
            results = results.filter { $0.status == .pending }
        }
        
        // Status filter
        if let statusFilter = selectedStatusFilter {
            results = results.filter { $0.status == statusFilter }
        }
        
        // Peer filter
        if !peerFilter.isEmpty {
            let query = peerFilter.lowercased()
            results = results.filter {
                $0.fromPubkey.lowercased().contains(query) ||
                $0.toPubkey.lowercased().contains(query) ||
                $0.counterpartyName.lowercased().contains(query)
            }
        }
        
        return results.sorted { $0.createdAt > $1.createdAt }
    }
    
    private var requestsList: some View {
        VStack(spacing: 0) {
            ForEach(filteredRequests) { request in
                PaymentRequestRow(
                    request: request,
                    viewModel: viewModel,
                    onTap: {
                        selectedRequest = request
                    },
                    onPayNow: {
                        initiatePayment(for: request)
                    }
                )
                
                if request.id != filteredRequests.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray6)
        .cornerRadius(8)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "bell.badge")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Payment Requests")
                .foregroundColor(.textPrimary)
            
            BodyMText("Create or receive payment requests")
                .foregroundColor(.textSecondary)
            
            Button {
                showingCreateRequest = true
            } label: {
                BodyMText("Create Request")
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.brandAccent)
                    .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func initiatePayment(for request: BitkitPaymentRequest) {
        Task {
            do {
                // Use Paykit URI to trigger proper method discovery
                let recipientPubkey = request.direction == .incoming
                    ? request.fromPubkey  // Pay the requester
                    : request.toPubkey    // Pay the recipient
                
                let result = try await PaykitPaymentService.shared.pay(
                    to: "paykit:\(recipientPubkey)",
                    amountSats: UInt64(request.amountSats),
                    peerPubkey: recipientPubkey
                )
                
                if result.success {
                    var updatedRequest = request
                    updatedRequest.status = .paid
                    try viewModel.updateRequest(updatedRequest)
                    app.toast(type: .success, title: "Payment sent!")
                } else {
                    app.toast(type: .error, title: "Payment failed", description: result.error?.localizedDescription)
                }
            } catch {
                app.toast(error)
            }
        }
    }
}

// MARK: - Filter Chip

private struct RequestFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            BodySText(title)
                .foregroundColor(isSelected ? .white : .textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.brandAccent : Color.gray5)
                .cornerRadius(16)
        }
    }
}

struct PaymentRequestRow: View {
    let request: BitkitPaymentRequest
    @ObservedObject var viewModel: PaymentRequestsViewModel
    var onTap: () -> Void = {}
    var onPayNow: () -> Void = {}
    @EnvironmentObject private var app: AppViewModel
    @State private var isProcessing = false
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // Direction indicator
                Image(systemName: request.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundColor(request.direction == .incoming ? .greenAccent : .brandAccent)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        BodyMBoldText(request.counterpartyName)
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        StatusBadge(status: request.status)
                    }
                    
                    BodyMText("\(formatSats(request.amountSats))")
                        .foregroundColor(.white)
                    
                    HStack(spacing: 8) {
                        BodySText(request.methodId.capitalized)
                            .foregroundColor(.textSecondary)
                        
                        if !request.description.isEmpty {
                            BodySText("• \(request.description)")
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    
                    // Description preview (metadata-like)
                    if !request.description.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                            BodySText(request.description)
                        }
                        .foregroundColor(.brandAccent)
                    }
                    
                    // Expiry
                    if let expiresAt = request.expiresAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            BodySText(expiryText(expiresAt))
                        }
                        .foregroundColor(isExpiringSoon(expiresAt) ? .orange : .textSecondary)
                    }
                }
                
                Spacer()
                
                // Action buttons
                if request.status == .pending {
                    actionButtons
                }
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        if request.direction == .incoming {
            // Incoming: Approve, Decline, Pay Now
            VStack(spacing: 8) {
                Button {
                    isProcessing = true
                    onPayNow()
                } label: {
                    HStack(spacing: 4) {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        BodySText("Pay")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.greenAccent)
                    .cornerRadius(8)
                }
                .disabled(isProcessing)
                
                HStack(spacing: 8) {
                    Button {
                        approveRequest()
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundColor(.greenAccent)
                            .font(.caption)
                            .frame(width: 28, height: 28)
                            .background(Color.greenAccent.opacity(0.2))
                            .cornerRadius(6)
                    }
                    
                    Button {
                        declineRequest()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.redAccent)
                            .font(.caption)
                            .frame(width: 28, height: 28)
                            .background(Color.redAccent.opacity(0.2))
                            .cornerRadius(6)
                    }
                }
            }
        } else {
            // Outgoing: Show status indicator
            Image(systemName: "chevron.right")
                .foregroundColor(.textSecondary)
                .font(.caption)
        }
    }
    
    private func approveRequest() {
        do {
            var updated = request
            updated.status = .accepted
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request accepted")
        } catch {
            app.toast(error)
        }
    }
    
    private func declineRequest() {
        do {
            var updated = request
            updated.status = .declined
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request declined")
        } catch {
            app.toast(error)
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func expiryText(_ date: Date) -> String {
        if date < Date() {
            return "Expired"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Expires \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
    
    private func isExpiringSoon(_ date: Date) -> Bool {
        let hoursUntilExpiry = date.timeIntervalSinceNow / 3600
        return hoursUntilExpiry < 24 && hoursUntilExpiry > 0
    }
}

struct StatusBadge: View {
    let status: PaymentRequestStatus
    
    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            BodySText(status.rawValue)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor)
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
        case .accepted:
            Image(systemName: "checkmark")
                .font(.caption2)
        case .declined:
            Image(systemName: "xmark")
                .font(.caption2)
        case .paid:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
        case .expired:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .pending: return .orange
        case .accepted: return .greenAccent
        case .declined: return .redAccent
        case .expired: return .gray2
        case .paid: return .greenAccent
        }
    }
}

// MARK: - Payment Request Detail Sheet

struct PaymentRequestDetailSheet: View {
    let request: BitkitPaymentRequest
    @ObservedObject var viewModel: PaymentRequestsViewModel
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessingPayment = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    statusSection
                    peerSection
                    methodSection
                    
                    if !request.description.isEmpty {
                        descriptionSection
                    }
                    
                    if request.status == .pending {
                        actionsSection
                    }
                }
                .padding(20)
            }
            .background(Color.gray5)
            .navigationTitle("Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(request.direction == .incoming ? Color.greenAccent.opacity(0.2) : Color.brandAccent.opacity(0.2))
                    .frame(width: 72, height: 72)
                
                Image(systemName: request.direction == .incoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(request.direction == .incoming ? .greenAccent : .brandAccent)
            }
            
            HeadlineText(formatSats(request.amountSats))
                .foregroundColor(.white)
            
            if !request.description.isEmpty {
                BodyMText(request.description)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Status")
                .foregroundColor(.textSecondary)
            
            HStack {
                StatusBadge(status: request.status)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    BodySText("Created")
                        .foregroundColor(.textSecondary)
                    BodySText(formatDate(request.createdAt))
                        .foregroundColor(.white)
                }
            }
            
            if let expiresAt = request.expiresAt {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.textSecondary)
                    
                    if expiresAt < Date() {
                        BodyMText("Expired on \(formatDate(expiresAt))")
                            .foregroundColor(.redAccent)
                    } else {
                        BodyMText("Expires \(formatDate(expiresAt))")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var peerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText(request.direction == .incoming ? "From" : "To")
                .foregroundColor(.textSecondary)
            
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    Text(String(request.counterpartyName.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.brandAccent)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyMBoldText(request.counterpartyName)
                        .foregroundColor(.white)
                    
                    BodySText(truncatePubkey(request.direction == .incoming ? request.fromPubkey : request.toPubkey))
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                Button {
                    let pubkey = request.direction == .incoming ? request.fromPubkey : request.toPubkey
                    UIPasteboard.general.string = pubkey
                    app.toast(type: .success, title: "Copied to clipboard")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.brandAccent)
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Payment Method")
                .foregroundColor(.textSecondary)
            
            HStack {
                Image(systemName: methodIcon)
                    .foregroundColor(.brandAccent)
                
                BodyMText(request.methodId.capitalized)
                    .foregroundColor(.white)
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var methodIcon: String {
        switch request.methodId.lowercased() {
        case "lightning": return "bolt.fill"
        case "onchain", "bitcoin": return "bitcoinsign.circle.fill"
        case "noise": return "antenna.radiowaves.left.and.right"
        default: return "creditcard.fill"
        }
    }
    
    private func metadataSection(_ metadata: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Invoice Details")
                .foregroundColor(.textSecondary)
            
            ForEach(Array(metadata.keys.sorted()), id: \.self) { key in
                if let value = metadata[key] {
                    HStack {
                        BodySText(key.capitalized)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodySText(value)
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BodyMBoldText("Description")
                .foregroundColor(.textSecondary)
            
            BodyMText(request.description)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            if request.direction == .incoming {
                Button {
                    isProcessingPayment = true
                    executePayment()
                } label: {
                    HStack {
                        if isProcessingPayment {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        BodyMBoldText("Pay Now")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.greenAccent)
                    .cornerRadius(12)
                }
                .disabled(isProcessingPayment)
                
                HStack(spacing: 12) {
                    Button {
                        approveRequest()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark")
                            BodyMText("Accept")
                        }
                        .foregroundColor(.greenAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.greenAccent.opacity(0.2))
                        .cornerRadius(12)
                    }
                    
                    Button {
                        declineRequest()
                    } label: {
                        HStack {
                            Image(systemName: "xmark")
                            BodyMText("Decline")
                        }
                        .foregroundColor(.redAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.redAccent.opacity(0.2))
                        .cornerRadius(12)
                    }
                }
            }
        }
    }
    
    private func executePayment() {
        Task {
            defer { isProcessingPayment = false }
            
            do {
                let result = try await PaykitPaymentService.shared.pay(
                    to: request.methodId == "lightning" ? "lightning:\(request.id)" : request.toPubkey,
                    amountSats: UInt64(request.amountSats),
                    peerPubkey: request.fromPubkey
                )
                
                if result.success {
                    var updated = request
                    updated.status = .paid
                    try viewModel.updateRequest(updated)
                    app.toast(type: .success, title: "Payment sent!")
                    dismiss()
                } else {
                    app.toast(type: .error, title: "Payment failed", description: result.error?.localizedDescription)
                }
            } catch {
                app.toast(error)
            }
        }
    }
    
    private func approveRequest() {
        do {
            var updated = request
            updated.status = .accepted
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request accepted")
            dismiss()
        } catch {
            app.toast(error)
        }
    }
    
    private func declineRequest() {
        do {
            var updated = request
            updated.status = .declined
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request declined")
            dismiss()
        } catch {
            app.toast(error)
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func truncatePubkey(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return "\(pubkey.prefix(8))...\(pubkey.suffix(8))"
    }
}

struct CreatePaymentRequestView: View {
    @ObservedObject var viewModel: PaymentRequestsViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    
    @State private var toPubkey = ""
    @State private var amount: Int64 = 1000
    @State private var methodId = "lightning"
    @State private var description = ""
    @State private var expiresInDays: Int = 7
    @State private var isSending = false
    @State private var showingContactPicker = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            BodyLText("Recipient")
                                .foregroundColor(.textPrimary)
                            
                            Spacer()
                            
                            Button {
                                showingContactPicker = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.crop.circle")
                                    Text("Contacts")
                                }
                                .foregroundColor(.brandAccent)
                                .font(.subheadline)
                            }
                        }
                        
                        TextField("Recipient Public Key (z-base32)", text: $toPubkey)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Payment Details")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", text: Binding(
                                get: { String(amount) },
                                set: { amount = Int64($0) ?? 0 }
                            ))
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .frame(width: 120)
                        }
                        
                        Picker("Payment Method", selection: $methodId) {
                            Text("Lightning").tag("lightning")
                            Text("On-Chain").tag("onchain")
                        }
                        .pickerStyle(.segmented)
                        
                        TextField("Description (optional)", text: $description)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                        
                        HStack {
                            BodyMText("Expires in:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Picker("Days", selection: $expiresInDays) {
                                Text("1 day").tag(1)
                                Text("7 days").tag(7)
                                Text("30 days").tag(30)
                                Text("90 days").tag(90)
                            }
                        }
                    }
                    
                    Button {
                        isSending = true
                        Task {
                            await viewModel.sendPaymentRequest(
                                recipientPubkey: toPubkey.trimmingCharacters(in: .whitespaces),
                                amountSats: amount,
                                methodId: methodId,
                                description: description,
                                expiresInDays: expiresInDays
                            )
                            isSending = false
                            
                            if viewModel.sendSuccess {
                                viewModel.sendSuccess = false
                                app.toast(type: .success, title: "Request sent")
                                dismiss()
                            } else if let error = viewModel.error {
                                app.toast(type: .error, title: "Failed to send", description: error)
                                viewModel.error = nil
                            }
                        }
                    } label: {
                        HStack {
                            if isSending {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            BodyMText(isSending ? "Sending..." : "Send Request")
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.brandAccent)
                        .cornerRadius(8)
                    }
                    .disabled(toPubkey.isEmpty || amount <= 0 || isSending)
                }
                .padding(16)
            }
            .navigationTitle("Create Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingContactPicker) {
                ContactPickerSheet(
                    onSelect: { contact in
                        toPubkey = contact.publicKeyZ32
                    },
                    onNavigateToDiscovery: {
                        navigation.navigate(.paykitContactDiscovery)
                    }
                )
            }
        }
    }
}

// ViewModel for Payment Requests
@MainActor
class PaymentRequestsViewModel: ObservableObject {
    @Published var requests: [BitkitPaymentRequest] = []
    @Published var incomingRequests: [BitkitPaymentRequest] = []
    @Published var outgoingRequests: [BitkitPaymentRequest] = []
    @Published var sentRequests: [SentPaymentRequest] = []
    @Published var selectedTab: RequestTab = .incoming
    @Published var isLoading = false
    @Published var isSending = false
    @Published var isCleaningUp = false
    @Published var isDiscovering = false
    @Published var sendSuccess = false
    @Published var cleanupResult: String?
    @Published var discoveryResult: String?
    @Published var error: String?
    
    private let storage: PaymentRequestStorage
    private let sentStorage: SentPaymentRequestStorage
    private let directoryService: DirectoryService
    private let identityName: String
    
    enum RequestTab {
        case incoming
        case sent
    }
    
    init(identityName: String? = nil, directoryService: DirectoryService = .shared) {
        // Use dynamic identity lookup like we fixed for Dashboard
        self.identityName = identityName ?? PaykitKeyManager.shared.getCurrentPublicKeyZ32() ?? "default"
        self.storage = PaymentRequestStorage(identityName: self.identityName)
        self.sentStorage = SentPaymentRequestStorage(identityName: self.identityName)
        self.directoryService = directoryService
    }
    
    func loadRequests() {
        isLoading = true
        requests = storage.listRequests()
        incomingRequests = requests.filter { $0.direction == .incoming }
        outgoingRequests = requests.filter { $0.direction == .outgoing }
        isLoading = false
    }
    
    func loadSentRequests() {
        sentRequests = sentStorage.listSentRequests()
    }
    
    func discoverRequests() async {
        isDiscovering = true
        discoveryResult = nil
        
        guard let myPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            discoveryResult = "No identity configured"
            isDiscovering = false
            return
        }
        
        Logger.info("=== PAYMENT REQUEST DISCOVERY START ===", context: "PaymentRequestsVM")
        Logger.info("My full pubkey: \(myPubkey)", context: "PaymentRequestsVM")
        
        // Fetch follows from network (same as subscriptions)
        do {
            let follows = try await directoryService.fetchFollows()
            if follows.isEmpty {
                discoveryResult = "No follows. My pk: \(myPubkey.prefix(12))..."
                isDiscovering = false
                return
            }
            
            // Log discovery context (ContextId is symmetric so we compute per-peer)
            Logger.info("My pubkey: \(myPubkey.prefix(12))..., will check ContextId paths for each follow", context: "PaymentRequestsVM")
            Logger.info("Follows (peers to check): \(follows)", context: "PaymentRequestsVM")
            
            discoveryResult = "Polling \(follows.count) peers..."
            
            var discovered = 0
            for peerPubkey in follows {
                do {
                    let discoveredRequests = try await directoryService.discoverPendingRequestsFromPeer(
                        peerPubkey: peerPubkey,
                        myPubkey: myPubkey
                    )
                    Logger.info("Found \(discoveredRequests.count) requests from \(peerPubkey.prefix(12))...", context: "PaymentRequestsVM")
                    
                    for discoveredRequest in discoveredRequests {
                        // Check if we already have this request
                        if !self.requests.contains(where: { $0.id == discoveredRequest.requestId }) {
                            // Convert DiscoveredRequest to BitkitPaymentRequest
                            let request = BitkitPaymentRequest(
                                id: discoveredRequest.requestId,
                                fromPubkey: discoveredRequest.fromPubkey,
                                toPubkey: myPubkey,
                                amountSats: discoveredRequest.amountSats,
                                currency: "SAT",
                                methodId: "lightning",
                                description: discoveredRequest.description ?? "",
                                createdAt: discoveredRequest.createdAt,
                                expiresAt: nil,
                                status: .pending,
                                direction: .incoming
                            )
                            try? addRequest(request)
                            discovered += 1
                        }
                    }
                } catch {
                    Logger.debug("No requests from \(peerPubkey.prefix(12))...: \(error.localizedDescription)", context: "PaymentRequestsVM")
                }
            }
            
            if discovered > 0 {
                discoveryResult = "Found \(discovered) new request(s)"
            } else {
                // Check for key sync issues
                let noiseKeypair = PaykitKeyManager.shared.getCachedNoiseKeypair()
                let hasNoiseKey = noiseKeypair != nil
                if !hasNoiseKey {
                    discoveryResult = "⚠️ No Noise key!\nReconnect to Pubky Ring"
                } else {
                    // Check if local key matches published endpoint
                    var keySyncIssue = false
                    if let publishedEndpoint = try? await directoryService.discoverNoiseEndpoint(for: myPubkey) {
                        if publishedEndpoint.serverNoisePubkey != noiseKeypair?.publicKey {
                            keySyncIssue = true
                            Logger.error("Key sync issue: local key doesn't match published endpoint", context: "PaymentRequestsVM")
                        }
                    }
                    
                    if keySyncIssue {
                        discoveryResult = "⚠️ Key sync issue!\nReconnect to Pubky Ring to fix"
                    } else {
                        discoveryResult = "0 requests found.\n\(follows.count) follows checked"
                    }
                }
            }
            
            loadRequests()
        } catch {
            discoveryResult = "Error: \(error.localizedDescription)"
        }
        
        isDiscovering = false
    }
    
    func addRequest(_ request: BitkitPaymentRequest) throws {
        try storage.addRequest(request)
        loadRequests()
    }
    
    func updateRequest(_ request: BitkitPaymentRequest) throws {
        try storage.updateRequest(request)
        loadRequests()
    }
    
    func deleteRequest(_ request: BitkitPaymentRequest) throws {
        try storage.deleteRequest(id: request.id)
        loadRequests()
    }
    
    func sendPaymentRequest(
        recipientPubkey: String,
        amountSats: Int64,
        methodId: String,
        description: String,
        expiresInDays: Int = 7
    ) async {
        isSending = true
        error = nil
        
        guard let senderPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            error = "No identity configured"
            isSending = false
            return
        }
        
        let requestId = UUID().uuidString
        let expiresAt = Calendar.current.date(byAdding: .day, value: expiresInDays, to: Date())
        
        let request = BitkitPaymentRequest(
            id: requestId,
            fromPubkey: senderPubkey,
            toPubkey: recipientPubkey,
            amountSats: amountSats,
            currency: "SAT",
            methodId: methodId,
            description: description,
            createdAt: Date(),
            expiresAt: expiresAt,
            status: .pending,
            direction: .outgoing
        )
        
        do {
            // Publish encrypted request to homeserver
            try await DirectoryService.shared.publishPaymentRequest(request, recipientPubkey: recipientPubkey)
            
            // Save to local storage
            try storage.addRequest(request)
            
            // Track for cleanup purposes
            sentStorage.saveSentRequest(
                requestId: requestId,
                recipientPubkey: recipientPubkey,
                amountSats: amountSats,
                methodId: methodId,
                description: description
            )
            
            loadRequests()
            loadSentRequests()
            sendSuccess = true
            Logger.info("Sent payment request \(requestId) to \(recipientPubkey.prefix(12))...", context: "PaymentRequestsVM")
        } catch {
            self.error = error.localizedDescription
            Logger.error("Failed to send payment request: \(error)", context: "PaymentRequestsVM")
        }
        
        isSending = false
    }
    
    func cancelSentRequest(_ request: SentPaymentRequest) async {
        do {
            // Delete from homeserver
            try await DirectoryService.shared.deletePaymentRequest(
                requestId: request.id,
                recipientPubkey: request.recipientPubkey
            )
            // Delete from local tracking
            sentStorage.deleteSentRequest(id: request.id)
            // Also remove from main requests list if exists
            try? storage.deleteRequest(id: request.id)
            
            loadRequests()
            loadSentRequests()
            Logger.info("Cancelled sent request: \(request.id)", context: "PaymentRequestsVM")
        } catch {
            self.error = error.localizedDescription
            Logger.error("Failed to cancel sent request: \(error)", context: "PaymentRequestsVM")
        }
    }
    
    func cleanupOrphanedRequests() async -> Int {
        isCleaningUp = true
        cleanupResult = nil
        
        let trackedIdsByRecipient = sentStorage.getSentRequestsByRecipient()
        guard !trackedIdsByRecipient.isEmpty else {
            isCleaningUp = false
            cleanupResult = "No sent requests to check"
            return 0
        }
        
        var totalDeleted = 0
        
        for (recipientPubkey, trackedIds) in trackedIdsByRecipient {
            do {
                let homeserverIds = try await DirectoryService.shared.listRequestsOnHomeserver(
                    recipientPubkey: recipientPubkey
                )
                let orphanedIds = homeserverIds.filter { !trackedIds.contains($0) }
                if !orphanedIds.isEmpty {
                    let deleted = await DirectoryService.shared.deleteRequestsBatch(
                        requestIds: orphanedIds,
                        recipientPubkey: recipientPubkey
                    )
                    totalDeleted += deleted
                }
            } catch {
                Logger.warn("Failed to check requests for \(recipientPubkey.prefix(12))...: \(error)", context: "PaymentRequestsVM")
            }
        }
        
        let message = totalDeleted > 0 ? "Cleaned up \(totalDeleted) orphaned requests" : "No orphaned requests found"
        cleanupResult = message
        isCleaningUp = false
        Logger.info(message, context: "PaymentRequestsVM")
        return totalDeleted
    }
}

// MARK: - Sent Request Row

struct SentRequestRow: View {
    let request: SentPaymentRequest
    var onTap: () -> Void = {}
    var onCancel: () -> Void = {}
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.brandAccent)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        BodyMBoldText(truncatePubkey(request.recipientPubkey))
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        SentStatusBadge(status: request.status)
                    }
                    
                    BodyMText("\(formatSats(request.amountSats))")
                        .foregroundColor(.white)
                    
                    HStack(spacing: 8) {
                        BodySText(request.methodId.capitalized)
                            .foregroundColor(.textSecondary)
                        
                        if let description = request.description, !description.isEmpty {
                            BodySText("• \(description)")
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    
                    BodySText("Sent \(formatRelativeDate(request.sentAt))")
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                if request.status == .pending {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.redAccent)
                            .font(.title3)
                    }
                }
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.textSecondary)
                    .font(.caption)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func truncatePubkey(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return "\(pubkey.prefix(8))...\(pubkey.suffix(8))"
    }
    
    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct SentStatusBadge: View {
    let status: SentPaymentRequest.SentRequestStatus
    
    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            BodySText(status.rawValue.capitalized)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor)
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
        case .paid:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
        case .expired:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .pending: return .orange
        case .paid: return .greenAccent
        case .expired: return .gray2
        }
    }
}

// MARK: - Sent Request Detail Sheet

struct SentRequestDetailSheet: View {
    let request: SentPaymentRequest
    @ObservedObject var viewModel: PaymentRequestsViewModel
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    statusSection
                    recipientSection
                    methodSection
                    
                    if let description = request.description, !description.isEmpty {
                        descriptionSection(description)
                    }
                    
                    if request.status == .pending {
                        actionsSection
                    }
                }
                .padding(20)
            }
            .background(Color.gray5)
            .navigationTitle("Sent Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.brandAccent.opacity(0.2))
                    .frame(width: 72, height: 72)
                
                Image(systemName: "arrow.up")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.brandAccent)
            }
            
            HeadlineText(formatSats(request.amountSats))
                .foregroundColor(.white)
            
            if let description = request.description, !description.isEmpty {
                BodyMText(description)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Status")
                .foregroundColor(.textSecondary)
            
            HStack {
                SentStatusBadge(status: request.status)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    BodySText("Sent")
                        .foregroundColor(.textSecondary)
                    BodySText(formatDate(request.sentAt))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Recipient")
                .foregroundColor(.textSecondary)
            
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    Text(String(request.recipientPubkey.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.brandAccent)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyMBoldText(truncatePubkey(request.recipientPubkey))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                Button {
                    UIPasteboard.general.string = request.recipientPubkey
                    app.toast(type: .success, title: "Copied to clipboard")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.brandAccent)
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Payment Method")
                .foregroundColor(.textSecondary)
            
            HStack {
                Image(systemName: methodIcon)
                    .foregroundColor(.brandAccent)
                
                BodyMText(request.methodId.capitalized)
                    .foregroundColor(.white)
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var methodIcon: String {
        switch request.methodId.lowercased() {
        case "lightning": return "bolt.fill"
        case "onchain", "bitcoin": return "bitcoinsign.circle.fill"
        case "noise": return "antenna.radiowaves.left.and.right"
        default: return "creditcard.fill"
        }
    }
    
    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BodyMBoldText("Description")
                .foregroundColor(.textSecondary)
            
            BodyMText(description)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var actionsSection: some View {
        Button {
            Task {
                await viewModel.cancelSentRequest(request)
                app.toast(type: .success, title: "Request cancelled")
                dismiss()
            }
        } label: {
            HStack {
                Image(systemName: "xmark.circle")
                BodyMBoldText("Cancel Request")
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.redAccent)
            .cornerRadius(12)
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func truncatePubkey(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return "\(pubkey.prefix(8))...\(pubkey.suffix(8))"
    }
}

// MARK: - Sent Payment Request Model

struct SentPaymentRequest: Codable, Identifiable, Hashable {
    let id: String
    let recipientPubkey: String
    let amountSats: Int64
    let methodId: String
    let description: String?
    let sentAt: Date
    var status: SentRequestStatus
    
    enum SentRequestStatus: String, Codable, Hashable {
        case pending
        case paid
        case expired
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: SentPaymentRequest, rhs: SentPaymentRequest) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Sent Payment Request Storage

class SentPaymentRequestStorage {
    private let keychain: PaykitKeychainStorage
    private let identityName: String
    
    private var sentRequestsKey: String {
        "paykit.sent_requests.\(identityName)"
    }
    
    private var cache: [SentPaymentRequest]?
    
    init(identityName: String, keychain: PaykitKeychainStorage = PaykitKeychainStorage()) {
        self.identityName = identityName
        self.keychain = keychain
    }
    
    func listSentRequests() -> [SentPaymentRequest] {
        if let cached = cache {
            return cached
        }
        
        do {
            guard let data = try keychain.retrieve(key: sentRequestsKey) else {
                return []
            }
            let requests = try JSONDecoder().decode([SentPaymentRequest].self, from: data)
                .sorted { $0.sentAt > $1.sentAt }
            cache = requests
            return requests
        } catch {
            Logger.error("Failed to load sent requests: \(error)", context: "SentPaymentRequestStorage")
            return []
        }
    }
    
    func saveSentRequest(
        requestId: String,
        recipientPubkey: String,
        amountSats: Int64,
        methodId: String,
        description: String?
    ) {
        var requests = listSentRequests()
        guard !requests.contains(where: { $0.id == requestId }) else { return }
        
        requests.insert(
            SentPaymentRequest(
                id: requestId,
                recipientPubkey: recipientPubkey,
                amountSats: amountSats,
                methodId: methodId,
                description: description,
                sentAt: Date(),
                status: .pending
            ),
            at: 0
        )
        persistRequests(requests)
    }
    
    func deleteSentRequest(id: String) {
        var requests = listSentRequests()
        requests.removeAll { $0.id == id }
        persistRequests(requests)
    }
    
    func getSentRequestsByRecipient() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for request in listSentRequests() {
            if result[request.recipientPubkey] == nil {
                result[request.recipientPubkey] = []
            }
            result[request.recipientPubkey]?.insert(request.id)
        }
        return result
    }
    
    private func persistRequests(_ requests: [SentPaymentRequest]) {
        do {
            let data = try JSONEncoder().encode(requests)
            try keychain.store(key: sentRequestsKey, data: data)
            cache = requests
        } catch {
            Logger.error("Failed to persist sent requests: \(error)", context: "SentPaymentRequestStorage")
        }
    }
}


