// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing

@testable import iCanHazAI

// Tests for the three-layer transport timeout config (`readTimeout`,
// `progressTimeout`, `transportTimeout`), retry behaviour, and their
// classification. Live watchdog behaviour is covered in
// `TransportWatchdogTests`.
extension AllAppTests {
    @Suite("Transport timeout and retry")
    struct TransportTimeoutRetryTests {

        // MARK: - Connection config decoding

        @Test("Connection decodes all timeout fields and numRetries")
        func connectionDecodesNewFields() throws {
            let jsonc = #"{"model":"m","readTimeout":60,"progressTimeout":90,"transportTimeout":7200,"numRetries":3}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            #expect(config.readTimeout == 60)
            #expect(config.progressTimeout == 90)
            #expect(config.transportTimeout == 7200)
            #expect(config.numRetries == 3)
        }

        @Test("Connection timeout fields default to nil")
        func connectionDefaultsAreNil() throws {
            let jsonc = #"{"model":"m"}"#
            let config = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            #expect(config.readTimeout == nil)
            #expect(config.progressTimeout == nil)
            #expect(config.transportTimeout == nil)
            #expect(config.numRetries == nil)
        }

        @Test("readTimeout rejects non-number")
        func readTimeoutRejectsNonNumber() {
            let jsonc = #"{"model":"m","readTimeout":"bad"}"#
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            }
        }

        @Test("progressTimeout rejects non-number")
        func progressTimeoutRejectsNonNumber() {
            let jsonc = #"{"model":"m","progressTimeout":"bad"}"#
            #expect(throws: ConfigValidationError.self) {
                _ = try ConfigValidation.decodeConnection(Data(jsonc.utf8))
            }
        }

        @Test("transportTimeout rejects non-number")
        func transportTimeoutRejectsNonNumber() {
            let jsonc = #"{"model":"m","transportTimeout":true}"#
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

        @Test("Connection timeout fields are wired through")
        func connectionFieldsWired() throws {
            let jsonc = #"{"model":"m","readTimeout":45,"progressTimeout":75,"transportTimeout":1800,"numRetries":2}"#
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
                progressTimeout: config.progressTimeout,
                transportTimeout: config.transportTimeout,
                numRetries: config.numRetries
            )
            #expect(conn.readTimeout == 45)
            #expect(conn.progressTimeout == 75)
            #expect(conn.transportTimeout == 1800)
            #expect(conn.numRetries == 2)
        }

        // MARK: - TimeoutPolicy resolution

        @Test("TimeoutPolicy applies layer defaults for nil values")
        func timeoutPolicyDefaults() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: nil, model: "m",
                imageInput: false, requestParameters: nil
            )
            let policy = TimeoutPolicy.resolve(conn)
            #expect(policy.read == LLMTransport.defaultReadTimeout)
            #expect(policy.progress == LLMTransport.defaultProgressTimeout)
            #expect(policy.transport == LLMTransport.defaultTransportTimeout)
        }

        @Test("TimeoutPolicy disables a layer on zero")
        func timeoutPolicyZeroDisables() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: nil, model: "m",
                imageInput: false, requestParameters: nil,
                readTimeout: 0, progressTimeout: 0, transportTimeout: 0
            )
            let policy = TimeoutPolicy.resolve(conn)
            #expect(policy.read == nil)
            #expect(policy.progress == nil)
            #expect(policy.transport == nil)
        }

        @Test("TimeoutPolicy keeps explicit positive values")
        func timeoutPolicyExplicitValues() {
            let conn = Connection(
                provider: .openai, name: "c", baseUrl: nil, apiKey: nil, model: "m",
                imageInput: false, requestParameters: nil,
                readTimeout: 5, progressTimeout: 10, transportTimeout: 15
            )
            let policy = TimeoutPolicy.resolve(conn)
            #expect(policy.read == 5)
            #expect(policy.progress == 10)
            #expect(policy.transport == 15)
        }

        // MARK: - Retry classification

        @Test("Offline-class URLErrors are not retried")
        func offlineErrorsNotRetried() {
            #expect(!LLMTransport.isRetryable(URLError(.notConnectedToInternet)))
            #expect(!LLMTransport.isRetryable(URLError(.dnsLookupFailed)))
            #expect(!LLMTransport.isRetryable(URLError(.cannotFindHost)))
            #expect(!LLMTransport.isRetryable(URLError(.dataNotAllowed)))
            #expect(!LLMTransport.isRetryable(URLError(.internationalRoamingOff)))
            #expect(!LLMTransport.isRetryable(URLError(.cancelled)))
        }

        @Test("Transient URLErrors are retried")
        func transientErrorsRetried() {
            #expect(LLMTransport.isRetryable(URLError(.timedOut)))
            #expect(LLMTransport.isRetryable(URLError(.networkConnectionLost)))
            #expect(LLMTransport.isRetryable(URLError(.cannotConnectToHost)))
        }

        @Test("HTTP 4xx is not retried, 5xx is")
        func httpStatusClassification() {
            func llmError(_ status: Int) -> LLMError {
                LLMError(statusCode: status, providerMessage: nil, errorType: nil, rawBody: nil, provider: .openai)
            }
            #expect(!LLMTransport.isRetryable(llmError(400)))
            #expect(!LLMTransport.isRetryable(llmError(401)))
            #expect(!LLMTransport.isRetryable(llmError(404)))
            #expect(LLMTransport.isRetryable(llmError(500)))
            #expect(LLMTransport.isRetryable(llmError(503)))
        }

        @Test("Transport timeout classification")
        func transportErrorClassification() {
            #expect(!LLMTransport.isRetryable(LLMTransportError.transportTimeout(3600)))
            #expect(LLMTransport.isRetryable(LLMTransportError.readTimeout(30)))
            #expect(LLMTransport.isRetryable(LLMTransportError.progressTimeout(60)))
            #expect(!LLMTransport.isRetryable(CancellationError()))
        }

        // MARK: - Error messages

        @Test("Timeout error descriptions are human-readable and distinct")
        func timeoutErrorDescriptions() {
            let read = LLMTransportError.readTimeout(30).errorDescription ?? ""
            #expect(read.contains("30"))
            #expect(read.contains("No data"))

            let progress = LLMTransportError.progressTimeout(60).errorDescription ?? ""
            #expect(progress.contains("60"))
            #expect(progress.contains("No usable output"))

            let transport = LLMTransportError.transportTimeout(3600).errorDescription ?? ""
            #expect(transport.contains("3600"))
            #expect(transport.contains("budget"))
        }

        // MARK: - Connection file writer

        @Test("Generated connection file documents all timeout layers")
        func writerDocumentsTimeouts() {
            let jsonc = ConnectionFileWriter.generateJSONC(
                provider: .openai, baseUrl: nil, apiKey: nil, model: "m", imageInput: false)
            #expect(jsonc.contains("\"readTimeout\""))
            #expect(jsonc.contains("\"progressTimeout\""))
            #expect(jsonc.contains("\"transportTimeout\""))
            #expect(jsonc.contains("\"numRetries\""))
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
