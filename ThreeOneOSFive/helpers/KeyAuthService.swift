import Foundation
import UIKit

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
/// No implementa la verificación de firma (signature) de las respuestas;
/// eso añade protección extra contra manipulación de red, pero no es
/// necesario para que la validación básica funcione.
actor KeyAuthService {
    static let shared = KeyAuthService()

    private var sessionId: String?

    private var hwid: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: KeyAuthConfig.apiBaseURL) else {
            throw KeyAuthError.network("URL de API inválida.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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

    /// Valida una license key contra KeyAuth. Lanza error si es inválida.
    func validate(key: String) async throws {
        if sessionId == nil {
            try await initialize()
        }
        guard let sessionId else {
            throw KeyAuthError.invalidResponse
        }

        let params: [String: String] = [
            "type": "license",
            "key": key,
            "hwid": hwid,
            "sessionid": sessionId,
        ]
        let json = try await post(params)

        guard (json["success"] as? Bool) == true else {
            let message = json["message"] as? String ?? "Key inválida."
            throw KeyAuthError.server(message)
        }
    }
}
