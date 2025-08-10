import Foundation
import CoreBluetooth
import CryptoKit

// MARK: - BLE Security and Authentication Support

/// Security configuration for BLE connections
public struct SecurityConfiguration: Sendable, Codable {
    public let requirePairing: Bool
    public let requireEncryption: Bool
    public let requireAuthentication: Bool
    public let encryptionKeySize: UInt8
    public let bondingType: BondingType
    
    public init(
        requirePairing: Bool = true,
        requireEncryption: Bool = true,
        requireAuthentication: Bool = true,
        encryptionKeySize: UInt8 = 16,
        bondingType: BondingType = .mitm
    ) {
        self.requirePairing = requirePairing
        self.requireEncryption = requireEncryption
        self.requireAuthentication = requireAuthentication
        self.encryptionKeySize = encryptionKeySize
        self.bondingType = bondingType
    }
    
    /// Default secure configuration
    public static let secure = SecurityConfiguration()
    
    /// Configuration for testing/development (less secure)
    public static let development = SecurityConfiguration(
        requirePairing: false,
        requireEncryption: false,
        requireAuthentication: false
    )
}

/// Bonding and pairing types
public enum BondingType: Sendable, Codable, CaseIterable {
    case none
    case mitm  // Man-in-the-middle protection
    case lesc  // LE Secure Connections
    case oob   // Out-of-band authentication
    
    public var description: String {
        switch self {
        case .none:
            return "No bonding"
        case .mitm:
            return "MITM protection"
        case .lesc:
            return "LE Secure Connections"
        case .oob:
            return "Out-of-band authentication"
        }
    }
}

/// Authentication state for a BLE connection
public enum AuthenticationState: Sendable, Codable {
    case unauthenticated
    case authenticating
    case authenticated(Date) // Authentication timestamp
    case authenticationFailed(BleuError)
    
    public var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

/// Device trust level
public enum TrustLevel: Sendable, Codable, CaseIterable {
    case untrusted
    case temporary
    case trusted
    case verified
    
    public var description: String {
        switch self {
        case .untrusted:
            return "Untrusted"
        case .temporary:
            return "Temporarily trusted"
        case .trusted:
            return "Trusted"
        case .verified:
            return "Verified"
        }
    }
}

/// Security credentials for device authentication
public struct SecurityCredentials: Sendable, Codable {
    public let deviceIdentifier: DeviceIdentifier
    public let trustLevel: TrustLevel
    public let authenticationState: AuthenticationState
    public let encryptionKey: Data?
    public let certificateChain: [Data]?
    public let lastAuthenticated: Date?
    public let expirationDate: Date?
    
    public init(
        deviceIdentifier: DeviceIdentifier,
        trustLevel: TrustLevel = .untrusted,
        authenticationState: AuthenticationState = .unauthenticated,
        encryptionKey: Data? = nil,
        certificateChain: [Data]? = nil,
        lastAuthenticated: Date? = nil,
        expirationDate: Date? = nil
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.trustLevel = trustLevel
        self.authenticationState = authenticationState
        self.encryptionKey = encryptionKey
        self.certificateChain = certificateChain
        self.lastAuthenticated = lastAuthenticated
        self.expirationDate = expirationDate
    }
    
    /// Check if credentials are valid and not expired
    public var isValid: Bool {
        guard authenticationState.isAuthenticated else { return false }
        
        if let expirationDate = expirationDate {
            return Date() < expirationDate
        }
        
        return true
    }
}

// MARK: - Security Manager

/// Manages BLE security, authentication, and encryption
public actor BleuSecurityManager {
    public static let shared = BleuSecurityManager()
    
    private var deviceCredentials: [DeviceIdentifier: SecurityCredentials] = [:]
    private var securityConfiguration: SecurityConfiguration = .secure
    private var trustedDevices: Set<DeviceIdentifier> = []
    
    private init() {}
    
    // MARK: - Security Configuration
    
    /// Update security configuration
    public func configure(with configuration: SecurityConfiguration) {
        self.securityConfiguration = configuration
    }
    
    /// Get current security configuration
    public var securityConfiguration: SecurityConfiguration {
        return securityConfiguration
    }
    
    // MARK: - Device Trust Management
    
    /// Add a device to the trusted list
    public func trustDevice(_ deviceId: DeviceIdentifier, level: TrustLevel = .trusted) {
        trustedDevices.insert(deviceId)
        
        // Update or create credentials
        var credentials = deviceCredentials[deviceId] ?? SecurityCredentials(deviceIdentifier: deviceId)
        credentials = SecurityCredentials(
            deviceIdentifier: credentials.deviceIdentifier,
            trustLevel: level,
            authenticationState: credentials.authenticationState,
            encryptionKey: credentials.encryptionKey,
            certificateChain: credentials.certificateChain,
            lastAuthenticated: credentials.lastAuthenticated,
            expirationDate: credentials.expirationDate
        )
        deviceCredentials[deviceId] = credentials
    }
    
    /// Remove a device from trusted list
    public func untrustDevice(_ deviceId: DeviceIdentifier) {
        trustedDevices.remove(deviceId)
        deviceCredentials.removeValue(forKey: deviceId)
    }
    
    /// Check if a device is trusted
    public func isTrusted(_ deviceId: DeviceIdentifier) -> Bool {
        return trustedDevices.contains(deviceId)
    }
    
    /// Get trust level for a device
    public func trustLevel(for deviceId: DeviceIdentifier) -> TrustLevel {
        return deviceCredentials[deviceId]?.trustLevel ?? .untrusted
    }
    
    // MARK: - Authentication
    
    /// Authenticate a device connection
    public func authenticateDevice(
        _ deviceId: DeviceIdentifier,
        using method: AuthenticationMethod
    ) async throws -> SecurityCredentials {
        
        // Update authentication state to authenticating
        var credentials = deviceCredentials[deviceId] ?? SecurityCredentials(deviceIdentifier: deviceId)
        credentials = SecurityCredentials(
            deviceIdentifier: credentials.deviceIdentifier,
            trustLevel: credentials.trustLevel,
            authenticationState: .authenticating,
            encryptionKey: credentials.encryptionKey,
            certificateChain: credentials.certificateChain,
            lastAuthenticated: credentials.lastAuthenticated,
            expirationDate: credentials.expirationDate
        )
        deviceCredentials[deviceId] = credentials
        
        do {
            // Perform authentication based on method
            let authResult = try await performAuthentication(deviceId: deviceId, method: method)
            
            // Update credentials with successful authentication
            credentials = SecurityCredentials(
                deviceIdentifier: credentials.deviceIdentifier,
                trustLevel: authResult.trustLevel,
                authenticationState: .authenticated(Date()),
                encryptionKey: authResult.encryptionKey,
                certificateChain: authResult.certificateChain,
                lastAuthenticated: Date(),
                expirationDate: Calendar.current.date(byAdding: .hour, value: 24, to: Date()) // 24-hour expiration
            )
            deviceCredentials[deviceId] = credentials
            
            return credentials
            
        } catch {
            // Update credentials with failed authentication
            credentials = SecurityCredentials(
                deviceIdentifier: credentials.deviceIdentifier,
                trustLevel: .untrusted,
                authenticationState: .authenticationFailed(error as? BleuError ?? BleuError.authenticationFailed),
                encryptionKey: nil,
                certificateChain: nil,
                lastAuthenticated: credentials.lastAuthenticated,
                expirationDate: nil
            )
            deviceCredentials[deviceId] = credentials
            
            throw error
        }
    }
    
    // MARK: - Encryption
    
    /// Encrypt data for transmission to a specific device
    public func encryptData(_ data: Data, for deviceId: DeviceIdentifier) throws -> Data {
        guard let credentials = deviceCredentials[deviceId],
              let encryptionKey = credentials.encryptionKey else {
            throw BleuError.authenticationFailed
        }
        
        return try performEncryption(data: data, key: encryptionKey)
    }
    
    /// Decrypt data received from a specific device
    public func decryptData(_ encryptedData: Data, from deviceId: DeviceIdentifier) throws -> Data {
        guard let credentials = deviceCredentials[deviceId],
              let encryptionKey = credentials.encryptionKey else {
            throw BleuError.authenticationFailed
        }
        
        return try performDecryption(data: encryptedData, key: encryptionKey)
    }
    
    // MARK: - Security Validation
    
    /// Validate if a connection meets security requirements
    public func validateConnection(_ deviceId: DeviceIdentifier) throws {
        let credentials = deviceCredentials[deviceId]
        
        if securityConfiguration.requireAuthentication {
            guard let creds = credentials, creds.authenticationState.isAuthenticated else {
                throw BleuError.authenticationFailed
            }
        }
        
        if securityConfiguration.requirePairing {
            guard let creds = credentials, creds.trustLevel != .untrusted else {
                throw BleuError.authenticationFailed
            }
        }
        
        if securityConfiguration.requireEncryption {
            guard let creds = credentials, creds.encryptionKey != nil else {
                throw BleuError.authenticationFailed
            }
        }
        
        // Check if credentials are not expired
        if let creds = credentials, !creds.isValid {
            throw BleuError.authenticationFailed
        }
    }
    
    // MARK: - Private Implementation
    
    private func performAuthentication(
        deviceId: DeviceIdentifier,
        method: AuthenticationMethod
    ) async throws -> AuthenticationResult {
        // This is a simplified implementation
        // In a real-world scenario, this would involve:
        // - Challenge-response authentication
        // - Certificate validation
        // - Key exchange protocols
        
        switch method {
        case .presharedKey(let key):
            return AuthenticationResult(
                trustLevel: .trusted,
                encryptionKey: key,
                certificateChain: nil
            )
            
        case .certificate(let cert):
            // Validate certificate chain
            guard validateCertificate(cert) else {
                throw BleuError.authenticationFailed
            }
            
            return AuthenticationResult(
                trustLevel: .verified,
                encryptionKey: generateEncryptionKey(),
                certificateChain: [cert]
            )
            
        case .challengeResponse:
            // Perform challenge-response authentication
            let encryptionKey = try await performChallengeResponse(deviceId: deviceId)
            
            return AuthenticationResult(
                trustLevel: .trusted,
                encryptionKey: encryptionKey,
                certificateChain: nil
            )
        }
    }
    
    private func performEncryption(data: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        return sealedBox.combined ?? Data()
    }
    
    private func performDecryption(data: Data, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
    
    private func validateCertificate(_ certificate: Data) -> Bool {
        // Certificate validation logic
        // In production, this would validate against a trusted CA
        return certificate.count > 0
    }
    
    private func generateEncryptionKey() -> Data {
        return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
    
    private func performChallengeResponse(deviceId: DeviceIdentifier) async throws -> Data {
        // Challenge-response implementation
        // This would involve sending a challenge to the device and validating the response
        return generateEncryptionKey()
    }
}

// MARK: - Supporting Types

/// Authentication methods supported by Bleu
public enum AuthenticationMethod: Sendable {
    case presharedKey(Data)
    case certificate(Data)
    case challengeResponse
}

/// Result of device authentication
private struct AuthenticationResult {
    let trustLevel: TrustLevel
    let encryptionKey: Data?
    let certificateChain: [Data]?
}

// MARK: - Security Extensions

extension BleuMessage {
    /// Create an encrypted message
    public static func encrypted(
        serviceUUID: UUID,
        characteristicUUID: UUID,
        data: Data,
        for deviceId: DeviceIdentifier,
        method: RequestMethod = .write
    ) async throws -> BleuMessage {
        
        let encryptedData = try await BleuSecurityManager.shared.encryptData(data, for: deviceId)
        
        return BleuMessage(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: encryptedData,
            method: method
        )
    }
    
    /// Decrypt this message if it's encrypted
    public func decrypted(from deviceId: DeviceIdentifier) async throws -> Data? {
        guard let data = self.data else { return nil }
        return try await BleuSecurityManager.shared.decryptData(data, from: deviceId)
    }
}

extension CentralActor {
    /// Connect to a device with security validation
    public distributed func secureConnect(to deviceId: DeviceIdentifier) async throws -> PeripheralActor {
        // Perform standard connection
        let peripheralActor = try await connect(to: deviceId)
        
        // Validate security requirements
        try await BleuSecurityManager.shared.validateConnection(deviceId)
        
        return peripheralActor
    }
}

extension PeripheralActor {
    /// Start advertising with security requirements
    public distributed func secureStartAdvertising() async throws {
        // Validate security configuration before advertising
        let securityConfig = await BleuSecurityManager.shared.getSecurityConfiguration()
        
        if securityConfig.requireEncryption || securityConfig.requireAuthentication {
            print("Starting advertising with security requirements: \(securityConfig)")
        }
        
        try await startAdvertising()
    }
}