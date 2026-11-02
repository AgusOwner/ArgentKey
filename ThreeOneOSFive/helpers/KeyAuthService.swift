import Foundation

enum KeyAuthError: LocalizedError {
    case network(String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .server(let message): return message
        case .invalidResponse: return "Respuesta inválida del servidor."
        }
    }
}

/// Cliente mínimo para la API 1.3 de KeyAuth: inicializa sesión y valida una key.
actor KeyAuthService {
    static let shared = KeyAuthService()

    private var sessionId: String?

    private var hwid: String { ActivationLedger.hwid }

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: KeyAuthConfig.apiBaseURL) else {
            throw KeyAuthError.network("URL de API inválida.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = params
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
            }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, _): (Data, URLResponse)
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw KeyAuthError.network("No se pudo conectar con KeyAuth. Revisa tu conexión.")
        }

        let rawText = String(data: data, encoding: .utf8) ?? "<no decodificable>"
        log("keyauth: response for type=\(params["type"] ?? "?") -> \(rawText)")

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw KeyAuthError.invalidResponse
        }
        return json
    }

    /// Inicializa la sesión con KeyAuth. Se debe llamar antes de validar una key.
    func initialize() async throws {
        let params: [String: String] = [
            "type": "init",
            "name": KeyAuthConfig.name,
            "ownerid": KeyAuthConfig.ownerid,
            "secret": KeyAuthConfig.secret,
            "ver": KeyAuthConfig.version,
            "hash": "",
        ]
        let json = try await post(params)

        guard (json["success"] as? Bool) == true else {
            let message = json["message"] as? String ?? "No se pudo inicializar KeyAuth."
            throw KeyAuthError.server(message)
        }
        sessionId = json["sessionid"] as? String
    }

    /// Valida una license key contra KeyAuth. Lanza error si es inválida,
    /// si ya se activó en este dispositivo o si pertenece a otro equipo.
    func validate(key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeyAuthError.server("Key inválida.")
        }

        // El llavero sobrevive a la desinstalación, así que una key ya usada
        // se rechaza aquí aunque la app se haya borrado y reinstalado.
        if ActivationLedger.isBurned(trimmed) {
            throw KeyAuthError.server(
                "Esta key ya fue activada en este dispositivo. Usa una key nueva."
            )
        }

        if sessionId == nil {
            try await initialize()
        }
        guard let sessionId else {
            throw KeyAuthError.invalidResponse
        }

        let params: [String: String] = [
            "type": "license",
            "key": trimmed,
            "hwid": hwid,
            "sessionid": sessionId,
            "name": KeyAuthConfig.name,
            "ownerid": KeyAuthConfig.ownerid,
        ]
        let json = try await post(params)

        guard (json["success"] as? Bool) == true else {
            let raw = (json["message"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            throw KeyAuthError.server(Self.spanish(raw))
        }

        // Solo se quema cuando KeyAuth confirmó la activación.
        ActivationLedger.burn(trimmed)
    }

    private static func spanish(_ raw: String) -> String {
        let value = raw.lowercased()
        guard !value.isEmpty else { return "Key inválida." }
        if value.contains("max uses") || value.contains("already used") || value.contains("reached") {
            return "Esta key ya fue usada y no puede volver a activarse. Pide una nueva."
        }
        if value.contains("hwid") || value.contains("hardware") {
            return "Esta key ya está vinculada a otro dispositivo."
        }
        if value.contains("expired") { return "La key caducó." }
        if value.contains("not found") || value.contains("does not exist") { return "La key no existe." }
        if value.contains("banned") { return "La key está baneada." }
        return raw
    }
}