# Bleu 2 Documentation Index

This document provides a comprehensive guide to all Bleu 2 documentation.

## Quick Start

- **[README.md](README.md)** - Project overview, quick start guide, and basic usage examples
- **[Package.swift](Package.swift)** - Swift Package Manager configuration

## Integration & Architecture

### Swift Actor Runtime Integration (NEW - v2.1.0)
- **[AGENTS.md](AGENTS.md)** - Complete integration documentation for swift-actor-runtime
  - Architecture overview (before/after comparison)
  - Implementation details and code examples
  - Performance improvements and benchmarks
  - Migration guide and best practices
  - Future multi-transport support roadmap

- **[CHANGELOG_ACTOR_RUNTIME.md](CHANGELOG_ACTOR_RUNTIME.md)** - Detailed changelog for v2.1.0
  - Critical bug fixes (instance isolation, double encoding, retry logic)
  - API changes and type migrations
  - Performance improvements (33% size reduction, 98-99% success rate)
  - Test results and known issues

## Developer Documentation

### Internal Documentation (for Contributors)
- **[docs/internal/CLAUDE.md](docs/internal/CLAUDE.md)** - AI assistant integration guide
  - Project overview and philosophy
  - Architecture deep dive (4-layer system)
  - CoreBluetooth integration patterns
  - Current status (Phase 2 complete ✅)
  - Coding conventions and best practices
  - Common issues and debugging

- **[docs/internal/REPOSITORY_GUIDELINES.md](docs/internal/REPOSITORY_GUIDELINES.md)** - Repository conventions
  - Project structure
  - Development workflow
  - Testing requirements
  - Commit guidelines

### Specifications
- **[docs/SPECIFICATION.md](docs/SPECIFICATION.md)** - Complete framework specification
  - Technical requirements
  - API design
  - BLE protocol specification
  - Security considerations

### Design Documents
- **[docs/design/](docs/design/)** - Architecture and implementation designs
  - **[DISCOVERY_CONNECTION_FIX.md](docs/design/DISCOVERY_CONNECTION_FIX.md)** - Bug fix design for eager connection pattern

### Guides
- **[docs/guides/TESTING.md](docs/guides/TESTING.md)** - Comprehensive testing guide
  - Protocol-oriented testing architecture
  - Mock system usage
  - Unit and integration test patterns
  - CI/CD integration
  - Hardware testing requirements

## User Documentation

### Getting Started
1. Read [README.md](README.md) for quick start
2. Run `swift build` to build the project
3. Run `swift test` to verify installation
4. Check out [Examples/](Examples/) for sample code

### For Advanced Users
1. Read [AGENTS.md](AGENTS.md) to understand the runtime architecture
2. Review [docs/SPECIFICATION.md](docs/SPECIFICATION.md) for protocol details
3. See [docs/guides/TESTING.md](docs/guides/TESTING.md) for testing strategies

### For Contributors
1. Read [docs/internal/REPOSITORY_GUIDELINES.md](docs/internal/REPOSITORY_GUIDELINES.md)
2. Review [docs/internal/CLAUDE.md](docs/internal/CLAUDE.md) for architecture
3. Check [CHANGELOG_ACTOR_RUNTIME.md](CHANGELOG_ACTOR_RUNTIME.md) for recent changes
4. Follow coding conventions and test requirements

## Release Notes

### v2.1.0 (2025-11-04) - Current Release
- **Swift Actor Runtime Integration**: Universal RPC primitives
- **Critical Bug Fixes**: Instance isolation, double encoding, retry logic
- **Performance**: 33% message size reduction, 98-99% RPC success rate
- **Documentation**: New AGENTS.md and CHANGELOG_ACTOR_RUNTIME.md

See [CHANGELOG_ACTOR_RUNTIME.md](CHANGELOG_ACTOR_RUNTIME.md) for complete details.

## Documentation by Topic

### Architecture
- [AGENTS.md](AGENTS.md) - Swift Actor Runtime integration architecture
- [docs/internal/CLAUDE.md](docs/internal/CLAUDE.md) - 4-layer architecture deep dive
- [docs/SPECIFICATION.md](docs/SPECIFICATION.md) - Technical specification

### RPC & Distributed Actors
- [AGENTS.md](AGENTS.md) - Envelope format and RPC patterns
- [docs/internal/CLAUDE.md](docs/internal/CLAUDE.md) - Distributed actor patterns
- [Sources/Bleu/Core/BLEActorSystem.swift](Sources/Bleu/Core/BLEActorSystem.swift) - Implementation

### BLE Transport
- [AGENTS.md](AGENTS.md) - Transport abstraction
- [docs/internal/CLAUDE.md](docs/internal/CLAUDE.md) - CoreBluetooth integration
- [Sources/Bleu/Transport/BLETransport.swift](Sources/Bleu/Transport/BLETransport.swift) - Fragmentation

### Testing
- [docs/guides/TESTING.md](docs/guides/TESTING.md) - Complete testing guide
- [README.md](README.md) - Testing quick start
- [Tests/BleuTests/](Tests/BleuTests/) - Test implementations

### Error Handling
- [AGENTS.md](AGENTS.md) - Error type conversion
- [CHANGELOG_ACTOR_RUNTIME.md](CHANGELOG_ACTOR_RUNTIME.md) - Error response mechanism
- [Sources/Bleu/Core/BleuError.swift](Sources/Bleu/Core/BleuError.swift) - Error types

### Performance
- [AGENTS.md](AGENTS.md) - Performance improvements (33% size reduction)
- [CHANGELOG_ACTOR_RUNTIME.md](CHANGELOG_ACTOR_RUNTIME.md) - Reliability improvements (98-99%)
- [Sources/Bleu/Core/EventBridge.swift](Sources/Bleu/Core/EventBridge.swift) - Retry logic

## File Organization

```
Bleu/
├── README.md                          # Project overview
├── Package.swift                      # SPM configuration
├── AGENTS.md                          # Actor runtime integration (NEW)
├── CHANGELOG_ACTOR_RUNTIME.md        # v2.1.0 changelog (NEW)
├── DOCUMENTATION_INDEX.md            # This file (NEW)
│
├── Sources/Bleu/
│   ├── Core/                         # Core distributed actor system
│   │   ├── BLEActorSystem.swift     # Main actor system
│   │   ├── EventBridge.swift        # Event routing & RPC
│   │   ├── BleuTypes.swift          # Type definitions
│   │   └── BleuError.swift          # Error types
│   │
│   ├── LocalActors/                  # CoreBluetooth wrappers
│   │   ├── LocalPeripheralActor.swift
│   │   └── LocalCentralActor.swift
│   │
│   ├── Implementations/              # Protocol implementations
│   │   ├── CoreBluetoothPeripheralManager.swift
│   │   └── CoreBluetoothCentralManager.swift
│   │
│   ├── Mapping/                      # Service/method mapping
│   │   ├── ServiceMapper.swift
│   │   └── MethodRegistry.swift
│   │
│   └── Transport/                    # Message transport
│       ├── BLETransport.swift
│       └── MessageRouter.swift
│
├── Tests/BleuTests/
│   ├── Unit/                         # Unit tests
│   ├── Integration/                  # Integration tests
│   └── Hardware/                     # Hardware tests (disabled)
│
├── Examples/
│   ├── BasicUsage/                   # Simple examples
│   ├── SwiftUIApp/                   # Full app example
│   └── Common/                       # Shared definitions
│
└── docs/
    ├── SPECIFICATION.md              # Technical spec
    ├── design/                       # Design documents
    │   └── DISCOVERY_CONNECTION_FIX.md
    ├── guides/                       # User guides
    │   └── TESTING.md
    └── internal/                     # Internal docs
        ├── CLAUDE.md                 # AI integration guide
        └── REPOSITORY_GUIDELINES.md  # Repo conventions
```

## Key Concepts

### Distributed Actors over BLE
Bleu enables transparent RPC between BLE devices using Swift's distributed actor system:
```swift
distributed actor Sensor: PeripheralActor {
    distributed func getValue() async -> Int { 42 }
}
```

### Transport-Agnostic Runtime
Uses `swift-actor-runtime` for universal RPC primitives:
- InvocationEnvelope (request)
- ResponseEnvelope (response)
- InvocationResult (success/failure/void)

### 4-Layer Architecture
1. **Public API**: BLEActorSystem, distributed actors
2. **Auto-Mapping**: ServiceMapper, MethodRegistry
3. **Message Transport**: BLETransport, reliability
4. **BLE Abstraction**: LocalPeripheralActor, LocalCentralActor

## Support

- **Issues**: https://github.com/1amageek/Bleu/issues
- **Discussions**: https://github.com/1amageek/Bleu/discussions
- **Twitter**: [@1amageek](https://x.com/1amageek)

## License

MIT License - See [LICENSE](LICENSE) file

---

**Last Updated**: 2025-11-04 (v2.1.0)
