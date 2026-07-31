import XCTest
@testable import Throttle

final class EdgeDeployServiceTests: XCTestCase {

    func testEdgeMCPDefinitionRoutesToBearerGatedStreamableEndpoint() throws {
        let data = try EdgeDeployService.edgeMCPDefinition(
            baseURL: "http://100.64.0.12:8787/", token: "secret-token")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "http")
        XCTAssertEqual(object["url"] as? String, "http://100.64.0.12:8787/mcp")
        let headers = try XCTUnwrap(object["headers"] as? [String: String])
        XCTAssertEqual(headers["Authorization"], "Bearer secret-token")
    }

    func testEdgeMCPDefinitionRejectsMalformedBaseURL() {
        XCTAssertThrowsError(
            try EdgeDeployService.edgeMCPDefinition(baseURL: "not a url", token: "x"))
    }
}
