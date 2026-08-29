// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import iCanHazAI

// Tests for read timeout, retry behaviour, and the new connection fields
// (`readTimeout`, `numRetries`) that control them.
extension AllAppTests {
    @Suite("Transport timeout and retry")
    struct TransportTimeoutRetryTests {

        // MARK: - Connection config decoding

        @Test("Connection decodes readTimeout and numRetries")
        func connectionDecodesNewFields() throws {
            let jsonc = #"{"model":"m","readTimeout":60,"numRetries":3}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            #expect(config.readTimeout == 60)
            #expect(config.numRetries == 3)
        }

        @Test("Connection defaults for new fields are nil")
        func connectionDefaultsAreNil() throws {
            let jsonc = #"{"model":"m"}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            #expect(config.readTimeout == nil)
            #expect(config.numRetries == nil)
        }

        @Test("readTimeout rejects non-number")
        func readTimeoutRejectsNonNumber() {
            let jsonc = #"{"model":"m","readTimeout":"bad"}"#
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            }
        }

        @Test("numRetries rejects non-integer")
        func numRetriesRejectsNonInteger() {
            let jsonc = #"{"model":"m","numRetries":1.5}"#
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            }
        }

        // MARK: - Connection model wiring

        @Test("Connection readTimeout and numRetries are wired through")
        func connectionFieldsWired() throws {
            let jsonc = #"{"model":"m","readTimeout":45,"numRetries":2}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            let conn = Connection(
                provider: .openai,
                name: "test",
                baseUrl: nil,
                apiKey: nil,
                model: config.model,
                imageInput: false,
                requestParameters: nil,
                readTimeout: config.readTimeout,
                numRetries: config.numRetries
            )
            #expect(conn.readTimeout == 45)
            #expect(conn.numRetries == 2)
        }

        @Test("Connection defaults readTimeout to 30 and numRetries to 1 in transport")
        func connectionDefaultsUsedByTransport() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: nil, model: "m",
                imageInput: false, requestParameters: nil
            )
            #expect(conn.readTimeout == nil)
            #expect(conn.numRetries == nil)
        }

        // MARK: - LLMTransportError

        @Test("readTimeout error description is human-readable")
        func readTimeoutErrorDescription() {
            let error = LLMTransportError.readTimeout(30)
            let desc = error.errorDescription ?? ""
            #expect(desc.contains("30"))
            #expect(desc.contains("timed out"))
        }

        // MARK: - Retry delay math

        @Test("Retry delays follow exponential backoff")
        func retryDelaySequence() {
            let delays = (1...3).map { pow(2.0, Double($0 - 1)) }
            #expect(delays[0] == 1.0)
            #expect(delays[1] == 2.0)
            #expect(delays[2] == 4.0)
        }
    }
}
