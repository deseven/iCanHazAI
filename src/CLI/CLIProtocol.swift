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
/// - `request` — a method call. Methods: `chat.send` (one-shot message,
///   optionally continuing an existing chat; `interactive` marks the chat as
///   driven by an interactive CLI session), `tool.approve` (the interactive
///   CLI's answer to an `approve` frame), `chat.stop` (stop the chat's stream
///   after the current iteration). Replies are correlated by `id`, so a
///   single connection can multiplex concurrent requests.
///
/// Server → client:
/// - `welcome` — greeting reply: session id, app version, and the negotiated
///   protocol version (the minimum of both peers').
/// - `pong` — liveness reply carrying the app version/pid.
/// - `started` — a request was accepted; carries the chat filename so the CLI
///   user can find the chat in the GUI.
/// - `delta` — a streamed response chunk for the request.
/// - `approve` — a tool call of an interactive-session chat needs the user's
///   confirmation; the client answers with a `tool.approve` request.
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
    /// A tool call began execution (`args` set, `status` nil) or produced its
    /// final result (`status` set). `args` is the collapsed one-line argument
    /// summary (see `ToolCall.summary`).
    case tool(id: String, name: String, args: String?, status: CLIToolStatus?)
    /// A tool call of an interactive-session chat awaits the user's
    /// confirmation. `args` is the collapsed one-line argument summary — the
    /// client never sees the full request. The client answers with a
    /// `tool.approve` request carrying `callID`.
    case approve(id: String, callID: String, name: String, args: String?)
    /// An out-of-band warning for the CLI user (not part of the chat
    /// content), printed to stderr by the client.
    case notice(id: String?, text: String)
    case done(id: String, chat: String, name: String?)
    case error(id: String?, code: String, message: String)
}

/// The final status of a tool call, carried by the `tool` frame. Mirrors
/// `ToolSummary.Status` in a flat, wire-friendly shape.
struct CLIToolStatus: Sendable, Equatable {
    /// "done" | "error" | "denied" | "cancelled".
    var kind: String
    /// Badge text ("done", "error", ...). Currently identical to `kind`.
    var label: String
    /// One-line description (may be empty).
    var description: String
}

/// A method call from the client. `method` is namespaced (`"chat.send"`) so
/// future request kinds slot in without changing the envelope.
struct CLIRequest: Sendable, Equatable {
    /// Send a message (creating or continuing a chat) and stream the reply.
    static let methodChatSend = "chat.send"
    /// Answer a tool-call approval prompt (interactive sessions only).
    static let methodToolApprove = "tool.approve"
    /// Stop the chat's stream after the current iteration.
    static let methodChatStop = "chat.stop"

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
    /// Filename of an existing chat to continue, with or without the ".json"
    /// extension. Nil → create a new chat.
    var chat: String?
    /// Create the new chat as a temporary one: in-memory only, destroyed when
    /// the client disconnects. Mutually exclusive with `chat`.
    var temporary = false
    /// Working directory for the chat (the CLI process's cwd unless -w was
    /// given). Only applied when the chat's role selects a workdir-capable
    /// built-in group (Filesystem/Code/Shell).
    var workdir: String?
    /// True when the workdir came from an explicit -w/--workdir flag rather
    /// than the implicit cwd default — drives the "role ignores it" warning.
    var workdirExplicit = false
    /// Auto-approve every tool call that would otherwise need confirmation.
    var allowAll = false
    /// The client is an interactive CLI session: tool calls that need
    /// confirmation are relayed to the client as `approve` frames instead of
    /// being skipped, and follow-up `chat.send` requests continue the chat.
    var interactive = false
    /// `tool.approve`: the call id from the `approve` frame being answered.
    var callID: String?
    /// `tool.approve`: "allow" (once), "allow_chat" (remember for this chat),
    /// or "deny".
    var decision: String?
    /// `tool.approve`: the optional reason for a "deny" decision.
    var reason: String?
    /// `chat.stop`: cancel the stream immediately (like the GUI's Stop)
    /// instead of after the current iteration.
    var immediate = false
}

enum CLIProtocolError: Error, Equatable {
    case unknownFrameType(String)
    case malformedFrame(String)
}

/// Frame codec. `encode` produces one line (JSON + `\n`); `decode` parses a
/// single line without the terminator.
enum CLIProtocol {

    /// Wire protocol version, sent as `v` in every frame. v2 added the
    /// interactive session frames (`approve`, `tool.approve`, `chat.stop`).
    static let version = 2

    private enum Key: String {
        case v, type, id, method, params, chat, text, code, message, client
        case session, name, summary, status, kind, label, description
        case decision, reason
        case callID = "call_id"
        case appVersion = "app_version"
        case protocolVersion = "protocol_version"
        case pid
    }

    private enum FrameType: String {
        case hello, welcome, ping, pong, request, started, delta, done, error
        case tool, notice, approve
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
            if req.params.temporary { params["temporary"] = true }
            if let workdir = req.params.workdir { params["workdir"] = workdir }
            if req.params.workdirExplicit { params["workdir_explicit"] = true }
            if req.params.allowAll { params["allow_all"] = true }
            if req.params.interactive { params["interactive"] = true }
            if let callID = req.params.callID { params[Key.callID.rawValue] = callID }
            if let decision = req.params.decision { params[Key.decision.rawValue] = decision }
            if let reason = req.params.reason { params[Key.reason.rawValue] = reason }
            if req.params.immediate { params["immediate"] = true }
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
        case .tool(let id, let name, let args, let status):
            obj[Key.type.rawValue] = FrameType.tool.rawValue
            obj[Key.id.rawValue] = id
            obj[Key.name.rawValue] = name
            if let args { obj[Key.summary.rawValue] = args }
            if let status {
                obj[Key.status.rawValue] = [
                    Key.kind.rawValue: status.kind,
                    Key.label.rawValue: status.label,
                    Key.description.rawValue: status.description,
                ]
            }
        case .approve(let id, let callID, let name, let args):
            obj[Key.type.rawValue] = FrameType.approve.rawValue
            obj[Key.id.rawValue] = id
            obj[Key.callID.rawValue] = callID
            obj[Key.name.rawValue] = name
            if let args { obj[Key.summary.rawValue] = args }
        case .notice(let id, let text):
            obj[Key.type.rawValue] = FrameType.notice.rawValue
            if let id { obj[Key.id.rawValue] = id }
            obj[Key.text.rawValue] = text
        case .done(let id, let chat, let name):
            obj[Key.type.rawValue] = FrameType.done.rawValue
            obj[Key.id.rawValue] = id
            obj[Key.chat.rawValue] = chat
            if let name { obj[Key.name.rawValue] = name }
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
                chat: paramsObj["chat"] as? String,
                temporary: paramsObj["temporary"] as? Bool ?? false,
                workdir: paramsObj["workdir"] as? String,
                workdirExplicit: paramsObj["workdir_explicit"] as? Bool ?? false,
                allowAll: paramsObj["allow_all"] as? Bool ?? false,
                interactive: paramsObj["interactive"] as? Bool ?? false,
                callID: paramsObj[Key.callID.rawValue] as? String,
                decision: paramsObj[Key.decision.rawValue] as? String,
                reason: paramsObj[Key.reason.rawValue] as? String,
                immediate: paramsObj["immediate"] as? Bool ?? false
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
        case FrameType.tool.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let name = obj[Key.name.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("tool frame missing id/name")
            }
            var status: CLIToolStatus?
            if let s = obj[Key.status.rawValue] as? [String: Any],
               let kind = s[Key.kind.rawValue] as? String,
               let label = s[Key.label.rawValue] as? String,
               let description = s[Key.description.rawValue] as? String {
                status = CLIToolStatus(kind: kind, label: label, description: description)
            }
            return .tool(id: id, name: name, args: obj[Key.summary.rawValue] as? String, status: status)
        case FrameType.approve.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let callID = obj[Key.callID.rawValue] as? String,
                  let name = obj[Key.name.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("approve frame missing id/call_id/name")
            }
            return .approve(id: id, callID: callID, name: name, args: obj[Key.summary.rawValue] as? String)
        case FrameType.notice.rawValue:
            guard let text = obj[Key.text.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("notice frame missing text")
            }
            return .notice(id: obj[Key.id.rawValue] as? String, text: text)
        case FrameType.done.rawValue:
            guard let id = obj[Key.id.rawValue] as? String,
                  let chat = obj[Key.chat.rawValue] as? String else {
                throw CLIProtocolError.malformedFrame("done frame missing id/chat")
            }
            return .done(id: id, chat: chat, name: obj[Key.name.rawValue] as? String)
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
