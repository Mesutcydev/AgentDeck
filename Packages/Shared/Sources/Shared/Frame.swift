//
//  Frame.swift
//  Shared — AgentDeck
//
//  §9 wire protocol v1 envelope (normative). Changes require an ADR and a
//  version bump. Field set is exactly: v, type, id, seq, ack, cursor, ts,
//  nonce, payload, sig — nothing more, nothing less.
//
//  Signing rule (normative): `sig` is Ed25519 (CryptoKit Curve25519.Signing)
//  over the RFC 8785 (JCS) canonical UTF-8 encoding of the frame with `sig`
//  ABSENT. All numbers are integers (JSONValue has no float case).
//

import Foundation

/// Namespaced frame types of wire protocol v1 (SPEC §9).
public enum FrameType: String, Sendable, CaseIterable {
    /// Carries a structured agent event (payload: AgentEvent).
    case sessionEvent = "session.event"
    /// Client → server on reconnect: replay events after `lastCursor` (§9, §14.1).
    case sessionResume = "session.resume"
    /// Companion → device: an approval request awaiting a decision.
    case approvalRequest = "approval.request"
    /// Device → companion: an approval decision (idempotent per requestID, §9).
    case approvalResolve = "approval.resolve"
    /// Keepalive (§9: 15 s interval; peer lost after 45 s silence).
    case heartbeat = "heartbeat"
    /// §13.2 pairing handshake (payloads in PairingMessages.swift). Added
    /// in Phase 3 within the v1 envelope (ADR-0008).
    case pairingHello = "pairing.hello"
    case pairingAccept = "pairing.accept"
    case pairingReject = "pairing.reject"
    case pairingConfirm = "pairing.confirm"
    case pairingComplete = "pairing.complete"
    /// §29 Phase 5 PTY output stream (ADR-0012).
    case terminalOutput = "terminal.output"
    /// §29 Phase 5 PTY input stream (ADR-0012).
    case terminalInput = "terminal.input"
    /// §29 Phase 6 client prompt to an active session (ADR-0013).
    case sessionPrompt = "session.prompt"
    /// §29 Phase 6 client request to START a session on the companion
    /// (ADR-0013 family; payload: SessionStartRequest).
    case sessionStart = "session.start"
    /// §29 Phase 6 client interrupt request (ADR-0013).
    case sessionInterrupt = "session.interrupt"
    /// §29 Phase 10 iOS push destination token registration (ADR-0015).
    case devicePushToken = "device.pushToken"
    /// §29 terminal lifecycle: launch a login-shell PTY in an authorized
    /// project (payload: TerminalStartRequest) and its answer
    /// (TerminalStartedResponse).
    case terminalStart = "terminal.start"
    case terminalStarted = "terminal.started"
    /// Device attach to a live PTY session; server replays scrollback.
    case terminalAttach = "terminal.attach"
    /// Device → companion PTY window resize (TIOCSWINSZ).
    case terminalResize = "terminal.resize"
    /// State sync: authorized-project inventory (payload: ProjectListResponse).
    case projectList = "project.list"
    case projectListResponse = "project.list.response"
    /// State sync: agent inventory (payload: AgentSnapshot); the snapshot is
    /// also pushed unprompted on connect and when session counts change.
    case agentList = "agent.list"
    case agentListResponse = "agent.list.response"
    case agentSnapshot = "agent.snapshot"
    /// Diff mirroring (payloads: DiffRequest / DiffContent).
    case diffRequest = "diff.request"
    case diffContent = "diff.content"
}

extension FrameType: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        guard let raw = jsonValue.stringValue, let value = FrameType(rawValue: raw) else {
            throw JSONValueDecodingError.invalidValue(
                field: "type", reason: "unknown frame type"
            )
        }
        self = value
    }

    public func toJSONValue() -> JSONValue { .string(rawValue) }
}

/// An unsigned §9 frame. The wire unit is `SignedFrame`; this is its input.
public struct Frame: Sendable, Equatable {
    /// Protocol version of this implementation. Frames with any other `v`
    /// are rejected on decode.
    public static let version: Int64 = 1

    /// Nonce length in bytes (§9: 16 random bytes per frame).
    public static let nonceLength = 16

    public var type: FrameType
    /// Unique per frame.
    public var id: UUID
    /// Per-direction, monotonic from 1 (§9).
    public var seq: UInt64
    /// Highest contiguous seq received from the peer (§9).
    public var ack: UInt64
    /// Resume position; present on event frames (§9).
    public var cursor: EventCursor?
    /// Unix milliseconds; accepted within ±30 s (§9).
    public var timestamp: Int64
    /// 16 random bytes; replay cache is keyed on it (§9).
    public var nonce: Data
    /// Versioned payload (every payload type carries `payloadV`, §9).
    public var payload: JSONValue

    public init(
        type: FrameType,
        id: UUID = UUID(),
        seq: UInt64,
        ack: UInt64,
        cursor: EventCursor? = nil,
        timestamp: Int64,
        nonce: Data,
        payload: JSONValue
    ) {
        self.type = type
        self.id = id
        self.seq = seq
        self.ack = ack
        self.cursor = cursor
        self.timestamp = timestamp
        self.nonce = nonce
        self.payload = payload
    }
}

/// A §9 frame plus its Ed25519 signature — the actual wire unit.
public struct SignedFrame: Sendable, Equatable {
    public var frame: Frame
    /// Ed25519 signature (64 bytes) over the JCS canonical encoding of the
    /// frame with `sig` absent (§9 signing rule).
    public var signature: Data

    public init(frame: Frame, signature: Data) {
        self.frame = frame
        self.signature = signature
    }
}

extension Frame {
    enum Field {
        static let v = "v"
        static let type = "type"
        static let id = "id"
        static let seq = "seq"
        static let ack = "ack"
        static let cursor = "cursor"
        static let ts = "ts"
        static let nonce = "nonce"
        static let payload = "payload"
        static let sig = "sig"
    }

    /// The object the signature covers: all fields with `sig` ABSENT (§9).
    /// Public so verify-only consumers (e.g. the relay, ARCHITECTURE §2)
    /// reproduce the exact normative signing input.
    public func signingJSONValue() throws -> JSONValue {
        try jsonValue(includeSignature: nil)
    }

    /// Full object. `includeSignature: nil` omits the sig field (signing
    /// input); a value embeds it (wire form). Cursor is omitted when nil
    /// (§9: present on event frames); decoding accepts absent or null.
    func jsonValue(includeSignature signature: Data?) throws -> JSONValue {
        guard nonce.count == Frame.nonceLength else {
            throw FrameError.invalidNonceLength(nonce.count)
        }
        var pairs: [(String, JSONValue)] = [
            (Field.v, .int(Frame.version)),
            (Field.type, type.toJSONValue()),
            (Field.id, .string(id.uuidString.lowercased())),
            (Field.seq, try JSONValue.u64(seq)),
            (Field.ack, try JSONValue.u64(ack)),
            (Field.ts, .int(timestamp)),
            (Field.nonce, .string(nonce.base64EncodedString())),
            (Field.payload, payload)
        ]
        if let cursor {
            pairs.append((Field.cursor, try cursor.toJSONValue()))
        }
        if let signature {
            pairs.append((Field.sig, .string(signature.base64EncodedString())))
        }
        return .object(pairs)
    }
}

extension SignedFrame: JSONValueConvertible {
    /// Decodes WITHOUT verifying the signature — verification is
    /// `FrameVerifier.verify` (a frame is never trusted before that call).
    public init(jsonValue: JSONValue) throws {
        let version = try jsonValue.intField(Frame.Field.v)
        guard version == Frame.version else {
            throw FrameError.unsupportedVersion(version)
        }
        guard let frameID = UUID(uuidString: try jsonValue.stringField(Frame.Field.id)) else {
            throw JSONValueDecodingError.invalidValue(field: Frame.Field.id, reason: "not a UUID")
        }
        let nonce = try Self.decodeBase64Field(jsonValue, Frame.Field.nonce)
        guard nonce.count == Frame.nonceLength else {
            throw FrameError.invalidNonceLength(nonce.count)
        }
        let signature = try Self.decodeBase64Field(jsonValue, Frame.Field.sig)
        guard signature.count == 64 else {
            throw FrameError.invalidSignatureLength(signature.count)
        }
        self.init(
            frame: Frame(
                type: try jsonValue.nestedField(Frame.Field.type, as: FrameType.self),
                id: frameID,
                seq: try jsonValue.u64Field(Frame.Field.seq),
                ack: try jsonValue.u64Field(Frame.Field.ack),
                cursor: try jsonValue.optionalNestedField(Frame.Field.cursor, as: EventCursor.self),
                timestamp: try jsonValue.intField(Frame.Field.ts),
                nonce: nonce,
                payload: try jsonValue.requiredField(Frame.Field.payload)
            ),
            signature: signature
        )
    }

    public func toJSONValue() throws -> JSONValue {
        guard signature.count == 64 else {
            throw FrameError.invalidSignatureLength(signature.count)
        }
        return try frame.jsonValue(includeSignature: signature)
    }

    private static func decodeBase64Field(_ jsonValue: JSONValue, _ field: String) throws -> Data {
        let text = try jsonValue.stringField(field)
        guard let data = Data(base64Encoded: text) else {
            throw JSONValueDecodingError.invalidValue(field: field, reason: "not base64")
        }
        return data
    }
}

/// Errors specific to the §9 wire protocol.
public enum FrameError: Error, Equatable {
    /// Frame exceeds the 1 MiB maximum (§9).
    case frameTooLarge(size: Int, limit: Int)
    /// Ed25519 verification failed, or the peer's canonical encoding differs.
    case invalidSignature
    /// `v` field is not 1.
    case unsupportedVersion(Int64)
    /// Nonce is not exactly 16 bytes (§9).
    case invalidNonceLength(Int)
    /// Signature is not exactly 64 bytes (Ed25519).
    case invalidSignatureLength(Int)
    /// `ts` outside the ±30 s acceptance window (§9).
    case timestampOutsideTolerance(deltaMilliseconds: Int64, toleranceMilliseconds: Int64)
    /// seq violates the per-direction monotonic-from-1 rule (§9).
    case invalidSequence(UInt64)
}
