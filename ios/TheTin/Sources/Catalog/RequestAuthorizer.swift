import Foundation

/// Authorizes a request against one origin. Called once normally; called a second time with
/// `refresh: true` after a 401, and the request is then retried exactly once.
///
/// This exists because the NAS and the R2 backup serve the *same* object layout and the *same*
/// manifest contract, and differ only in how a request proves it may read. Injecting that one
/// difference is what keeps a single tested remote implementation serving both origins — the
/// previous shape (a whole second `HTTPCatalogRemote`) is what let the Firebase-only casual
/// assumption rot into a silent tier bug.
typealias RequestAuthorizer = @Sendable (inout URLRequest, Bool) async throws -> Void

enum Authorizers {
    /// The self-hosted NAS: an App Attest–minted Bearer session token.
    static func appAttest(_ session: SessionProvider) -> RequestAuthorizer {
        { req, refresh in
            let token = refresh ? try await session.refreshedToken() : try await session.authToken()
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// The R2 backup origin: a Firebase App Check token, verified by the Worker against Google's
    /// JWKS. Deliberately a different chain from the NAS's — it does not route through the NAS, so
    /// a fresh install or an expired session can still reach the backup while the NAS is down.
    static func appCheck() -> RequestAuthorizer {
        { req, refresh in
            guard let token = await StorageAuth.appCheckToken(forcingRefresh: refresh) else {
                throw CatalogError.badResponse
            }
            req.setValue(token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
    }
}
