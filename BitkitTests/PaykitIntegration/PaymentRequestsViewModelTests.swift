// PaymentRequestsViewModelTests.swift
// BitkitTests
//
// Unit tests for PaymentRequestsViewModel

import XCTest
@testable import Bitkit

@MainActor
final class PaymentRequestsViewModelTests: XCTestCase {
    
    var viewModel: PaymentRequestsViewModel!
    private var testIdentity: String!
    
    override func setUp() {
        super.setUp()
        testIdentity = "test_\(UUID().uuidString)"
        viewModel = PaymentRequestsViewModel(identityName: testIdentity)
    }
    
    override func tearDown() {
        viewModel = nil
        testIdentity = nil
        super.tearDown()
    }
    
    // MARK: - Initial State Tests
    
    func testInitialStateHasEmptyRequests() {
        XCTAssertTrue(viewModel.requests.isEmpty)
        XCTAssertTrue(viewModel.incomingRequests.isEmpty)
        XCTAssertTrue(viewModel.outgoingRequests.isEmpty)
        XCTAssertTrue(viewModel.sentRequests.isEmpty)
    }
    
    func testInitialStateDefaultsToIncomingTab() {
        XCTAssertEqual(viewModel.selectedTab, .incoming)
    }
    
    func testInitialStateIsNotLoading() {
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertFalse(viewModel.isCleaningUp)
    }
    
    func testInitialStateHasNoError() {
        XCTAssertNil(viewModel.error)
        XCTAssertNil(viewModel.cleanupResult)
    }
    
    // MARK: - Load Requests Tests
    
    func testLoadRequestsUpdatesState() {
        // When
        viewModel.loadRequests()
        
        // Then
        XCTAssertFalse(viewModel.isLoading)
    }
    
    func testLoadSentRequestsUpdatesState() {
        // When
        viewModel.loadSentRequests()
        
        // Then - should complete without error
        // Empty list is expected for fresh test identity
        XCTAssertTrue(viewModel.sentRequests.isEmpty)
    }
    
    // MARK: - Add Request Tests
    
    func testAddRequestIncreasesCount() throws {
        // Given
        let request = createTestRequest(direction: .incoming)
        let initialCount = viewModel.requests.count
        
        // When
        try viewModel.addRequest(request)
        
        // Then
        XCTAssertEqual(viewModel.requests.count, initialCount + 1)
    }
    
    func testAddIncomingRequestShowsInIncomingList() throws {
        // Given
        let request = createTestRequest(direction: .incoming)
        
        // When
        try viewModel.addRequest(request)
        
        // Then
        XCTAssertEqual(viewModel.incomingRequests.count, 1)
        XCTAssertEqual(viewModel.incomingRequests.first?.id, request.id)
    }
    
    func testAddOutgoingRequestShowsInOutgoingList() throws {
        // Given
        let request = createTestRequest(direction: .outgoing)
        
        // When
        try viewModel.addRequest(request)
        
        // Then
        XCTAssertEqual(viewModel.outgoingRequests.count, 1)
        XCTAssertEqual(viewModel.outgoingRequests.first?.id, request.id)
    }
    
    // MARK: - Update Request Tests
    
    func testUpdateRequestChangesStatus() throws {
        // Given
        let request = createTestRequest(direction: .incoming, status: .pending)
        try viewModel.addRequest(request)
        
        // When
        var updated = request
        updated.status = .accepted
        try viewModel.updateRequest(updated)
        
        // Then
        let found = viewModel.requests.first { $0.id == request.id }
        XCTAssertEqual(found?.status, .accepted)
    }
    
    // MARK: - Delete Request Tests
    
    func testDeleteRequestRemovesFromList() throws {
        // Given
        let request = createTestRequest(direction: .incoming)
        try viewModel.addRequest(request)
        XCTAssertEqual(viewModel.requests.count, 1)
        
        // When
        try viewModel.deleteRequest(request)
        
        // Then
        XCTAssertEqual(viewModel.requests.count, 0)
    }
    
    // MARK: - Cleanup Tests
    
    func testCleanupOrphanedRequestsCompletesWithNoTrackedRequests() async {
        // When
        let deleted = await viewModel.cleanupOrphanedRequests()
        
        // Then
        XCTAssertEqual(deleted, 0)
        XCTAssertFalse(viewModel.isCleaningUp)
        XCTAssertNotNil(viewModel.cleanupResult)
    }
    
    // MARK: - Helper Methods
    
    private func createTestRequest(
        direction: RequestDirection,
        status: PaymentRequestStatus = .pending
    ) -> BitkitPaymentRequest {
        BitkitPaymentRequest(
            id: UUID().uuidString,
            fromPubkey: "pk:sender_\(UUID().uuidString)",
            toPubkey: "pk:recipient_\(UUID().uuidString)",
            amountSats: 1000,
            currency: "SAT",
            methodId: "lightning",
            description: "Test request",
            createdAt: Date(),
            expiresAt: Calendar.current.date(byAdding: .day, value: 7, to: Date()),
            status: status,
            direction: direction
        )
    }
}

