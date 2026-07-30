import Foundation
import Security

/// Loads the user-imported Docker TLS material (`ca.pem`, `cert.pem`, `key.pem`)
/// and turns it into the types the TLS stack needs: a `SecIdentity` for client
/// authentication and a CA certificate to anchor server verification.
///
/// The client certificate proves *us* to the host; the CA check verifies the
/// host to *us* — without it, anything on the LAN answering on `<ip>:2376`
/// would receive our client certificate and our commands. QNAP's Docker
/// certificate is issued to the NAS's own hostname while we connect by IP, so
/// the default hostname check can never pass; instead the chain is verified
/// against the imported `ca.pem` and only the name check is waived.
struct TLSIdentity {
    let identity: SecIdentity
    let caCertificate: SecCertificate

    enum TLSError: LocalizedError {
        case missingFile(String)
        case invalidPEM(String)
        case keyImportFailed
        case identityFailed

        var errorDescription: String? {
            switch self {
            case .missingFile(let name):
                return "Missing certificate file: \(name). Import ca.pem, cert.pem and key.pem in Settings → TLS Certificates."
            case .invalidPEM(let name):
                return "\(name) is not a valid PEM file."
            case .keyImportFailed:
                return "The private key could not be read (unsupported key format)."
            case .identityFailed:
                return "Could not build a client identity from cert.pem and key.pem."
            }
        }
    }

    // MARK: - PEM parsing

    /// Extracts the DER payload of the first PEM block matching one of `types`
    /// (e.g. "CERTIFICATE", "RSA PRIVATE KEY").
    static func pemBlock(in text: String, types: [String]) -> (type: String, der: Data)? {
        for type in types {
            let begin = "-----BEGIN \(type)-----"
            let end = "-----END \(type)-----"
            guard let start = text.range(of: begin), let stop = text.range(of: end) else { continue }
            let base64 = text[start.upperBound..<stop.lowerBound]
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard let der = Data(base64Encoded: base64) else { continue }
            return (type, der)
        }
        return nil
    }

    static func certificate(fromPEMFile url: URL) throws -> SecCertificate {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw TLSError.missingFile(url.lastPathComponent)
        }
        guard let block = pemBlock(in: text, types: ["CERTIFICATE"]),
              let cert = SecCertificateCreateWithData(nil, block.der as CFData) else {
            throw TLSError.invalidPEM(url.lastPathComponent)
        }
        return cert
    }

    static func privateKey(fromPEMFile url: URL) throws -> SecKey {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw TLSError.missingFile(url.lastPathComponent)
        }
        guard let block = pemBlock(in: text, types: [
            "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY"
        ]) else {
            throw TLSError.invalidPEM(url.lastPathComponent)
        }

        var der = block.der
        var keyType = kSecAttrKeyTypeRSA
        switch block.type {
        case "RSA PRIVATE KEY":
            keyType = kSecAttrKeyTypeRSA
        case "EC PRIVATE KEY":
            keyType = kSecAttrKeyTypeECSECPrimeRandom
        case "PRIVATE KEY":
            // PKCS#8: unwrap to the inner PKCS#1/SEC1 key that SecKey accepts.
            guard let unwrapped = unwrapPKCS8(der) else { throw TLSError.keyImportFailed }
            der = unwrapped.der
            keyType = unwrapped.isEC ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA
        default:
            break
        }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else {
            throw TLSError.keyImportFailed
        }
        return key
    }

    /// Minimal PKCS#8 unwrap: PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }.
    /// Returns the inner key bytes and whether the algorithm OID is EC.
    private static func unwrapPKCS8(_ data: Data) -> (der: Data, isEC: Bool)? {
        var reader = DERReader(data: data)
        guard reader.enterSequence() else { return nil }
        guard reader.skipElement() else { return nil }          // version INTEGER
        guard let algorithm = reader.readElement(tag: 0x30) else { return nil } // AlgorithmIdentifier
        guard let octets = reader.readElement(tag: 0x04) else { return nil }    // privateKey OCTET STRING

        // id-ecPublicKey = 1.2.840.10045.2.1 → DER 06 07 2A 86 48 CE 3D 02 01
        let ecOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let isEC = algorithm.range(of: Data(ecOID)) != nil
        return (octets, isEC)
    }

    private struct DERReader {
        let data: Data
        var offset: Data.Index

        init(data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func readTagLength() -> (tag: UInt8, length: Int, contentStart: Data.Index)? {
            guard offset < data.endIndex else { return nil }
            let tag = data[offset]
            var cursor = data.index(after: offset)
            guard cursor < data.endIndex else { return nil }
            var length = Int(data[cursor])
            cursor = data.index(after: cursor)
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4 else { return nil }
                length = 0
                for _ in 0..<count {
                    guard cursor < data.endIndex else { return nil }
                    length = (length << 8) | Int(data[cursor])
                    cursor = data.index(after: cursor)
                }
            }
            guard data.distance(from: cursor, to: data.endIndex) >= length else { return nil }
            return (tag, length, cursor)
        }

        /// Descends into a SEQUENCE (subsequent reads walk its children).
        mutating func enterSequence() -> Bool {
            guard let element = readTagLength(), element.tag == 0x30 else { return false }
            offset = element.contentStart
            return true
        }

        mutating func skipElement() -> Bool {
            guard let element = readTagLength() else { return false }
            offset = data.index(element.contentStart, offsetBy: element.length)
            return true
        }

        /// Reads the next element if it matches `tag`, returning its content bytes.
        mutating func readElement(tag: UInt8) -> Data? {
            guard let element = readTagLength(), element.tag == tag else { return nil }
            let end = data.index(element.contentStart, offsetBy: element.length)
            defer { offset = end }
            return data.subdata(in: element.contentStart..<end)
        }
    }

    // MARK: - Identity assembly

    /// `SecIdentity` can only be minted by the keychain, so the certificate and
    /// key are (re-)imported under an app-specific label and the matching
    /// identity queried back. Items are replaced on every load so re-imported
    /// certificates take effect immediately.
    static func load(certsDirectory: URL) throws -> TLSIdentity {
        let ca = try certificate(fromPEMFile: certsDirectory.appendingPathComponent("ca.pem"))
        let cert = try certificate(fromPEMFile: certsDirectory.appendingPathComponent("cert.pem"))
        let key = try privateKey(fromPEMFile: certsDirectory.appendingPathComponent("key.pem"))

        let label = "Portside Docker Client (\(certsDirectory.lastPathComponent))"

        // Replace any previous copies of this identity's parts.
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: label
        ] as CFDictionary)

        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: label
        ]
        let certStatus = SecItemAdd(certAdd as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw TLSError.identityFailed
        }

        let keyAdd: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: key,
            kSecAttrLabel as String: label
        ]
        let keyStatus = SecItemAdd(keyAdd as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw TLSError.identityFailed
        }

        // With both halves in the keychain, the identity query pairs them up.
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else {
            throw TLSError.identityFailed
        }

        let certData = SecCertificateCopyData(cert) as Data
        for candidate in identities {
            var candidateCert: SecCertificate?
            guard SecIdentityCopyCertificate(candidate, &candidateCert) == errSecSuccess,
                  let candidateCert else { continue }
            if SecCertificateCopyData(candidateCert) as Data == certData {
                return TLSIdentity(identity: candidate, caCertificate: ca)
            }
        }
        throw TLSError.identityFailed
    }

    /// Verifies a server trust chain against the imported CA, waiving only the
    /// hostname check (we connect by IP; the certificate names the NAS).
    static func evaluate(trust: SecTrust, against ca: SecCertificate) -> Bool {
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        // An X.509 policy without a hostname skips the name check but keeps
        // signature, validity and chain verification.
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    // MARK: - Certificate summaries (Settings display + expiry warnings)

    struct CertificateSummary {
        var commonName: String
        var notValidAfter: Date?
        var isExpired: Bool {
            guard let notValidAfter else { return false }
            return notValidAfter < Date()
        }
    }

    static func summary(ofPEMFile url: URL) -> CertificateSummary? {
        guard let cert = try? certificate(fromPEMFile: url) else { return nil }
        let name = SecCertificateCopySubjectSummary(cert) as String? ?? "—"

        var expiry: Date?
        var error: CFError?
        if let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, &error) as? [String: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
           let seconds = entry[kSecPropertyKeyValue as String] as? NSNumber {
            // The value is seconds since the reference date (2001-01-01).
            expiry = Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }
        return CertificateSummary(commonName: name, notValidAfter: expiry)
    }
}
