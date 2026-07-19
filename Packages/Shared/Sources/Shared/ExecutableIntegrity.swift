//
//  ExecutableIntegrity.swift
//  Shared — AgentDeck
//
//  Launch-time executable integrity. Discovery records a SHA-256 digest and
//  the code-signing team identifier for every accepted agent binary; the
//  companion re-verifies the same binary at launch time so an agent
//  executable replaced between discovery and launch is refused instead of
//  being spawned with the user's trust.
//
//  Team lookup uses Security.framework `SecStaticCode` APIs (no subprocess);
//  unsigned binaries — the common case for npm/brew-installed agent shims —
//  legitimately yield a nil team and are pinned by digest alone.
//

import CryptoKit
import Foundation

#if os(macOS)
import Security

public struct ExecutableFingerprint: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let codeSigningTeam: String?

    public init(path: String, sha256: String, codeSigningTeam: String?) {
        self.path = path
        self.sha256 = sha256
        self.codeSigningTeam = codeSigningTeam
    }
}

public enum ExecutableIntegrityError: Error, Equatable {
    case unreadable(path: String)
    case baselineMissing(path: String)
    case fingerprintMismatch(path: String, expectedSHA256: String, actualSHA256: String)
    case teamMismatch(path: String, expected: String?, actual: String?)
}

public enum ExecutableIntegrity {
    /// Streams the executable through SHA-256 and reads its code-signing
    /// team identifier (nil when unsigned).
    public static func fingerprint(atPath path: String) throws -> ExecutableFingerprint {
        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ExecutableIntegrityError.unreadable(path: path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw ExecutableIntegrityError.unreadable(path: path)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ExecutableFingerprint(
            path: path,
            sha256: digest,
            codeSigningTeam: codeSigningTeam(atPath: path)
        )
    }

    /// Code-signing team identifier via `SecStaticCode`; nil for unsigned
    /// or ad-hoc-signed binaries. Chosen over shelling out to
    /// `codesign -dvvv` so integrity checks never spawn a subprocess.
    public static func codeSigningTeam(atPath path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return nil
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Recomputes the fingerprint and compares it against a discovery-time
    /// baseline; throws a typed error on any mismatch.
    public static func verify(atPath path: String, against baseline: ExecutableFingerprint) throws {
        let current = try fingerprint(atPath: path)
        guard current.sha256 == baseline.sha256 else {
            throw ExecutableIntegrityError.fingerprintMismatch(
                path: path,
                expectedSHA256: baseline.sha256,
                actualSHA256: current.sha256
            )
        }
        guard current.codeSigningTeam == baseline.codeSigningTeam else {
            throw ExecutableIntegrityError.teamMismatch(
                path: path,
                expected: baseline.codeSigningTeam,
                actual: current.codeSigningTeam
            )
        }
    }
}

/// Process-wide baseline registry: `AgentDiscoveryService` records
/// fingerprints at discovery time; the companion launch path verifies
/// against them before spawning any adapter subprocess.
public final class ExecutableIntegrityRegistry: @unchecked Sendable {
    public static let shared = ExecutableIntegrityRegistry()

    private let lock = NSLock()
    private var baselines: [String: ExecutableFingerprint] = [:]

    public init() {}

    public func record(_ fingerprint: ExecutableFingerprint) {
        lock.lock()
        baselines[Self.canonicalKey(fingerprint.path)] = fingerprint
        lock.unlock()
    }

    public func baseline(forPath path: String) -> ExecutableFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return baselines[Self.canonicalKey(path)]
    }

    /// Verifies the executable against the recorded baseline. A missing
    /// baseline is a refusal: launching an agent discovery never fingerprinted
    /// defeats the point of the check.
    public func verify(executableAtPath path: String) throws {
        lock.lock()
        let baseline = baselines[Self.canonicalKey(path)]
        lock.unlock()
        guard let baseline else {
            throw ExecutableIntegrityError.baselineMissing(path: path)
        }
        try ExecutableIntegrity.verify(atPath: path, against: baseline)
    }

    /// Treats equivalent filesystem spellings (notably macOS' `/tmp` and
    /// `/private/tmp`) as the same executable identity.
    private static func canonicalKey(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    public func removeAll() {
        lock.lock()
        baselines.removeAll()
        lock.unlock()
    }
}
#endif
