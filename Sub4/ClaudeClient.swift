//
//  ClaudeClient.swift
//  Sub4
//
//  The Claude API, for the monthly review's second half.
//
//  WHAT THIS DOES AND DOES NOT DO
//  ------------------------------
//  It sends the evidence pack that `Review.markdown()` already computes, and
//  gets back a structured verdict. It does NOT send raw training data and ask
//  for arithmetic. That distinction is the whole design: adherence percentages,
//  mean RPE and volume totals are computed in Review.swift where they can be
//  checked, and a wrong number there would be visible. A wrong number produced
//  by a model inside a paragraph of reasoning would not be.
//
//  STRUCTURED OUTPUTS, NOT PROSE PARSING
//  -------------------------------------
//  The request carries `output_config.format` with a JSON schema, so the reply
//  is a document this app can decode rather than text it has to scrape. That is
//  generally available on the Claude API — no beta header. The result still
//  arrives in the ordinary text content block; it is simply guaranteed to match
//  the schema.
//
//  Schema constraints worth knowing, because they are not obvious: `$ref` is not
//  supported, and numeric/length bounds (`minimum`, `maxLength`, `pattern`) are
//  stripped. Anything that must be bounded has to be stated in the prompt and
//  then enforced in Swift after decoding — which is what ReviewProposal does.
//
//  THE KEY
//  -------
//  Keychain, exactly like the Strava secret, entered once in Settings and never
//  in source. Same honest trade-off as StravaAuth's header: on a personal phone
//  this is fine; the key is as safe as the device. If this app ever leaves your
//  hands, move the call behind a server and hand the phone a token instead.
//
//  Billing note for whoever reads this later: this is the Claude API, billed
//  separately from a Claude subscription. One review is a few thousand input
//  tokens — cents, not euros.
//

import Foundation

enum ClaudeConfig {

    private static let keychainKey = "claude.apiKey"

    static var apiKey: String? {
        get { Keychain.load(keychainKey, as: String.self) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.save(newValue, key: keychainKey)
            } else {
                Keychain.delete(keychainKey)
            }
        }
    }

    static var isConfigured: Bool {
        guard let k = apiKey else { return false }
        return !k.isEmpty
    }

    /// Chosen deliberately over Sonnet: the whole task is a judgement call on
    /// thin, noisy evidence, and the cost difference across the entire 34-week
    /// block is under a euro. Price is not the axis to optimise here.
    static let model = "claude-opus-5"

    static let apiVersion = "2023-06-01"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
}

// MARK: - Errors

enum ClaudeError: LocalizedError {
    case noKey
    case http(status: Int, message: String)
    case emptyReply
    case badShape(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            "No Claude API key. Add one in Settings → Claude API key."
        case .http(let status, let message):
            switch status {
            case 401: "The API key was rejected. Check it in Settings."
            case 429: "Rate limited. Wait a minute and try again."
            case 400: "The request was refused: \(message)"
            case 500...599: "Claude is unavailable right now (\(status)). Try again shortly."
            default: "HTTP \(status) — \(message)"
            }
        case .emptyReply:
            "Claude returned nothing to read."
        case .badShape(let why):
            "The reply did not match the expected shape: \(why)"
        }
    }
}

// MARK: - Client

enum ClaudeClient {

    /// Sends `prompt` and decodes the reply as `T`, using `schema` to force the
    /// shape. `schema` is a JSON Schema object as `[String: Any]`, because
    /// JSONSchema has no Swift type and hand-rolling one would buy nothing.
    static func structured<T: Decodable>(
        prompt: String,
        system: String,
        schema: [String: Any],
        maxTokens: Int = 4000,
        as type: T.Type
    ) async throws -> T {

        // THE SHARPEST OF THE FIVE GATES — patch 178, plan step 0.3.
        //
        // This is the only one that puts data on someone else's server. The
        // review payload carries CTL ramp figures, deep-TSB day counts,
        // monotony week counts, matched-session shares, recorded kilometres and
        // measured paces — every one computed from Strava data — plus the
        // athlete's own session notes verbatim. §5.3 of the Strava API Policy
        // bars using Strava Data "directly or indirectly … in connection with
        // the … operation of any AI Application"; §5.10 bars making it
        // available to "AI Application providers". ADR-0002 reads a computed
        // aggregate as in scope, because the alternative requires "indirectly"
        // to mean nothing.
        //
        // Checked BEFORE the key, deliberately. The other order reports "no API
        // key" to someone whose key is fine, and sends them to fix something
        // that is not broken.
        try ReleaseGates.require(.aiReview)

        guard let key = ClaudeConfig.apiKey, !key.isEmpty else { throw ClaudeError.noKey }

        let body: [String: Any] = [
            "model": ClaudeConfig.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["format": ["type": "json_schema",
                                        "schema": schema] as [String: Any]]
        ]

        var req = URLRequest(url: ClaudeConfig.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(ClaudeConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A review is not urgent and the model is thinking. The default 60 s
        // is the wrong shape for this call.
        req.timeoutInterval = 180

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.badShape("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClaudeError.http(status: http.statusCode,
                                   message: apiMessage(from: data))
        }

        // The structured result comes back in the ordinary text block — it is
        // simply guaranteed to parse. Several blocks can be present; the first
        // text one is the answer.
        guard let text = firstText(in: data) else { throw ClaudeError.emptyReply }
        guard let payload = text.data(using: .utf8) else {
            throw ClaudeError.badShape("reply was not UTF-8")
        }

        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            // Include a slice of what actually arrived. A decode failure with
            // no sight of the payload is the least debuggable error there is.
            throw ClaudeError.badShape("\(error.localizedDescription) — got: "
                                       + String(text.prefix(300)))
        }
    }

    // MARK: Response digging
    //
    // Done with JSONSerialization rather than Codable structs for the envelope.
    // The envelope gains fields over time and a strict Decodable model would
    // start failing on additions that do not concern us.

    private static func firstText(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else { return nil }
        for block in content where block["type"] as? String == "text" {
            if let t = block["text"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    private static func apiMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = root["error"] as? [String: Any],
              let msg = err["message"] as? String else {
            return String(data: data, encoding: .utf8)?.prefix(200).description ?? "no detail"
        }
        return msg
    }
}
