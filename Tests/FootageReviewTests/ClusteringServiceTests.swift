import Foundation
import Testing
@testable import FootageReview

@Suite("Clustering service boundaries")
@MainActor
struct ClusteringServiceTests {
    @Test func rejectsNonlocalAndCredentialEndpoints() {
        let rejected = ["https://127.0.0.1:8000", "http://localhost:8000", "http://example.com:8000", "http://127.0.0.1:8000/path", "http://token@127.0.0.1:8000", "http://127.0.0.1:8000?secret=value"]
        for value in rejected { #expect(!ClusteringAPIClient.validEndpoint(URL(string: value)!)) }
        #expect(ClusteringAPIClient.validEndpoint(URL(string: "http://127.0.0.1:12345")!))
        #expect(ClusteringAPIClient.segment("a/b?#%") == "a%2Fb%3F%23%25")
    }

    @Test func decodesOriginalIDsAndCompleteMembership() throws {
        let bytes = Data(#"{"id":"workspace","name":"Native review","library_id":"original-library","base_revision":7,"appearance_count":2,"export_complete":true,"groups":[{"id":"original-group","name":"Review","note":"Keep all members","appearance_ids":["original-1","outside-filter"],"origin":"existing","reviewed":true,"dirty":false,"similarity":null}],"jobs":[{"id":"job","workspace_id":"workspace","kind":"cluster","status":"paused","phase":"Paused","completed":1,"total":2,"error":null}],"imports":[]}"#.utf8)
        let value = try JSONDecoder().decode(ClusterWorkspace.self, from: bytes)
        #expect(value.libraryID == "original-library")
        #expect(value.baseRevision == 7)
        #expect(value.groups.first?.appearanceIDs == ["original-1", "outside-filter"])
        #expect(value.jobs.first?.workspaceID == value.id)
        #expect(value.jobs.first?.isActive == true)
    }

    @Test func savedImportPreviewKeepsIdentityAndRevision() throws {
        let bytes = Data(#"{"id":"saved-import","status":"uncertain","payload":{"import_id":"saved-import","base_revision":7,"groups":[]},"response":null,"error":"Response lost","created_at":"2026-11-08T00:00:00Z"}"#.utf8)
        let saved = try JSONDecoder().decode(ClusterSavedImport.self, from: bytes)
        let preview = try JSONDecoder().decode(ClusterJSON.self, from: Data(saved.prettyPayload.utf8))
        #expect(saved.status == "uncertain")
        #expect(preview == saved.payload)
        #expect(saved.id == "saved-import")
    }
}
