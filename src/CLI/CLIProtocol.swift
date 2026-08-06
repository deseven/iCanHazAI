// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The APP↔CLI wire protocol: newline-delimited JSON frames over the unix
/// control socket at `~/iCanHazAI/app.sock`.
///
/// Each frame is a single JSON object terminated by `\n` (JSON string escaping
/// guarantees no literal newlines inside a frame). Every frame carries a
/// protocol version (`v`) and a `type` discriminator; unknown keys are ignored
/// so newer peers can extend frames without breaking older ones.
///
/// Client → server:
/// - `hello` — the greeting that opens a session. Carries the client's PID
///   (verified by the server against the kernel-reported peer PID) and its
///   protocol version. Server replies with `welcome`.
/// - `ping` — liveness probe for long-lived sessions. Server replies `pong`.
/// - `request` — a method call. Currently only `chat.send` (one-shot message,
///   optionally continuing an existing chat). Replies are correlated by `id`,
///   so a single connection can multiplex concurrent requests (the basis for a
///   future interactive mode).
///
/// Server → client:
/// - `welcome` — greeting reply: session id, app version, and the negotiated
///   protocol version (the minimum of both peers').
/// - `pong` — liveness reply carrying the app version/pid.
/// - `started` — a request was accepted; carries the chat filename so the CLI
///   user can find the chat in the GUI.
/// - `delta` — a streamed response chunk for the request.
/// - `done` — the request completed successfully. Terminal.
/// - `error` — the request (or the connection, when `id` is nil) failed.
///   Terminal for that request.
enum CLIFrame: Sendable, Equatable {
    // Client → server
    case hello(pid: Int32, client: String, protocolVersion: Int)
    case ping
    case request(CLIRequest)
    // Server → client
    case welcome(session: String, appVersion: String, protocolVersion: Int)
    case pong(appVersion: String, pid: Int32)
    case started(id: String, chat: String)
    case delta(id: String, text: String)
    case done(id: String, chat: String)
    case error(id: String?, code: String, message: String)
}

/// A method call from the client. `method` is namespaced (`"chat.send"`) so
/// future request kinds (interactive input, tool approval, cancellation) slot
/// in without changing the envelope.
struct CLIRequest: Sendable, Equatable {
    /// The only currently-supported method.
    static let methodChatSend = "chat.send"

    var id: String
    var method: String
    var params: CLIRequestParams
}

/// Parameters for `chat.send`. `role`/`connection`/`chat` are optional
/// selectors; when nil the app's defaults are used / a new chat is created.
struct CLIRequestParams: Sendable, Equatable {
    var message: String
    /// Role for the new chat. Nil → the app's default role.
    var role: String?
    /// Connection override ("provider/name"). Nil → role/app default.
    var connection: String?
    /// Filename of an existing chat to continue. Nil → create a new chat.
    var chat: String?
}

enum CLIProtocolError: Error, Equatable {
    case unknownFrameType(String)
    case malformedFrame(String)
}

/// Frame codec. `encode` produces one line (JSON + `\n`); `decode` parses a
/// single line without the terminator.
enum CLIProtocol {

    /// Wire protocol version, sent as `v` in every frame.
    static let version = 1

    private enum Key: String {
        case v, type, id, method, params, chat, text, code, message, client
        case session
        case appVersion = "app_version"
        case protocolVersion = "protocol_version"
        case pid
    }

    private enum FrameType: String {
        case hello, welcome, ping, pong, request, started, delta, done, error
    }

    static func encode(_ frame: CLIFrame) throws -> Data {
        var obj: [String: Any] = [Key.v.rawValue: version]
        switch frame {
        case .hello(let pid, let client, let protocolVersion):
            obj[Key.type.rawValue] = FrameType.hello.rawValue
            obj[Key.pid.rawValue] = Int(pid)
            obj[Key.client.rawValue] = client
            obj[Key.protocolVersion.rawValue] = protocolVersion
        case .welcome(let session, let appVersion, let protocolVersion):
            obj[Key.type.rawValue] = FrameType.welcome.rawValue
            obj[Key.session.rawValue] = session
            obj[Key.appVersion.rawValue] = appVersion
            obj[Key.protocolVersion.rawValue] = protocolVersion
        case .ping:
            obj[Key.type.rawValue] = FrameType.ping.rawValue
        case .request(let req):
            obj[Key.type.rawValue] = FrameType.request.rawValue
            obj[Key.id.rawValue] = req.id
            obj[Key.method.rawValue] = req.method
            var params: [String: Any] = ["message": req.params.message]
            if let role = req.params.role { params["role"] = role }
            if let connection = req.params.connection { params["connection"] = connection }
            if let chat = req.params.chat { params["chat"] = chat }
            obj[Key.params.rawValue] = params
        case .pong(let appVersion, let pid):
            obj[Key.type.rawValue] = FrameType.pong.rawValue
            obj[Key.appVersion.rawValue] = appVersion
            obj[Key.pid.rawValue] = Int(pid)
        case .started(let id, let chat):
            obj[Key.type.rawValue] = FrameType.started.rawValue
            obj[Key.id.rawValue] = id
            obj[Key.chat.rawValue] = chat
        case .delta(let id, let text):
            obj[Key.type.rawValue] = FrameType.delta.rawValue
            obj[Key.id.rawValue] = id
            obj[Key.text.rawValue] = text
        case .done(let id, let chat):
            obj[Key.type.rawValue] = FrameType.done.rawValue
            obj[Key.id.rawValue] = id
            obj[Key.chat.rawValue] = chat
        case .error(let id, let code, let message):
            obj[Key.type.rawValue] = FrameType.error.rawValue
            if let id { obj[Key.id.rawValue] = id }
            obj[Key.code.rawValue] = code
            obj[Key.message.rawValue] = message
        }
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Decodes one frame from a line (without the `\n` terminator). Unknown
    /// keys are ignored; an unknown `type` throws `unknownFrameType`.
    static func decode(line: Data) throws -> CLIFrame {
        let raw = try JSONSerialization.jsonObject(with: line)
        guard let obj = raw as? [String: Any] else {
            throw CLIProtocolError.malformedFrame("frame is not a JSON object")
        }
        guard let type = obj[Key.type.rawValue] as? String else {
            throw CLIProtocolError.malformedFrame("frame has no string \"type\"")
        }
        switch type {
        case FrameType.hello.rawValue:
            guard let pid = obj[Key.pid.rawValue] as? Int,
                  let client = obj[Key.client.rawValue] as? String,
                  let protocolVersion = obj[Key.protocolVersion.rawValue] as? Int else {
                throw CLIProtocolError.malformedFrame("hello frame missing pid/client/protocol_version")
            }
            return .hello(pid: Int32(pid), client: client, protocolVersion: protocolVersion)
        case FrameType.welcome.rawValue:
            guard let session = obj[Key.session.rawValue] as? String,
                  let appVersion = obj[Key.appVersion.rawValue] as? String,
                  let protocolVersion = obj[Key.protocolVersion.rawValue] as? Int else {
                throw CLIProtocolError.malformedFrame("welcome frame missing session/app_version/protocol_version")
            }
            return .welcome(session: session, appVersion: appVersion, protocolVersion: protocolVersion)
        case FrameType.ping.rawValue:
            return .ping
        case FrameType.request.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let method = obj[Key.method.rawValue] as? String,
                  let paramsObj = obj[Key.params.rawValue] as? [String: Any],
                  let message = paramsObj["message"] as? String else {
                throw CLIProtocolError.malformedFrame("request frame missing id/method/params.message")
            }
            let params = CLIRequestParams(
                message: message,
                role: paramsObj["role"] as? String,
                connection: paramsObj["connection"] as? String,
                chat: paramsObj["chat"] as? String
            )
            return .request(CLIRequest(id: id, method: method, params: params))
        case FrameType.pong.rawValue:
            guard let appVersion = obj[Key.appVersion.rawValue] as? String,
                  let pid = obj[Key.pid.rawValue] as? Int else {
                throw CLIProtocolError.malformedFrame("pong frame missing app_version/pid")
            }
            return .pong(appVersion: appVersion, pid: Int32(pid))
        case FrameType.started.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let chat = obj[Key.chat.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("started frame missing id/chat")
            }
            return .started(id: id, chat: chat)
        case FrameType.delta.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let text = obj[Key.text.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("delta frame missing id/text")
            }
            return .delta(id: id, text: text)
        case FrameType.done.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let chat = obj[Key.chat.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("done frame missing id/chat")
            }
            return .done(id: id, chat: chat)
        case FrameType.error.rawValue:
            guard let code = obj[Key.code.rawValue] as? String,
                  let message = obj[Key.message.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("error frame missing code/message")
            }
            return .error(id: obj[Key.id.rawValue] as? String, code: code, message: message)
        default:
            throw CLIProtocolError.unknownFrameType(type)
        }
    }
}
