import Foundation

protocol PairingTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, Int)
}

private final class PairingRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Identity proofs and bearer tokens never follow a redirect, even to
    // another HTTPS origin controlled by the same operator.
    completionHandler(nil)
  }
}

final class URLSessionPairingTransport: PairingTransport, @unchecked Sendable {
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    session = URLSession(
      configuration: configuration, delegate: PairingRedirectPolicy(), delegateQueue: nil)
  }

  func send(_ request: URLRequest) async throws -> (Data, Int) {
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse,
      response.expectedContentLength <= 262_144
    else { throw PairingClientError.invalidResponse }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 262_144 else { throw PairingClientError.invalidResponse }
      data.append(byte)
    }
    return (data, response.statusCode)
  }
}
