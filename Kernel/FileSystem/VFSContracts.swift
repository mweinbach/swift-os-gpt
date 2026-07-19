/// Stable identifiers and metadata shared by filesystem providers, the VFS,
/// and future file-manager syscalls. None of these contracts expose physical
/// blocks, transport addresses, or provider-private inode layouts.
struct VFSVolumeIdentifier: RawRepresentable, Equatable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

enum VFSVolumeVisibility: UInt8, Equatable {
    /// A node-oriented provider that may participate in the user namespace.
    case namespace = 1
    /// Raw media, journal, kernel log, swap, and other kernel-owned storage.
    case kernelOnly = 2
}

struct VFSMountIdentifier: RawRepresentable, Equatable {
    let rawValue: UInt32

    init?(rawValue: UInt32) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct VFSNodeIdentifier: Equatable {
    let volume: VFSVolumeIdentifier
    let localValue: UInt64

    init?(volume: VFSVolumeIdentifier, localValue: UInt64) {
        guard localValue != 0 else { return nil }
        self.volume = volume
        self.localValue = localValue
    }
}

/// A role describes trust and persistence semantics, not a particular disk or
/// filesystem format. The same roles can be backed by SD, VirtIO, RAM, or a
/// future network provider without changing user-facing policy.
enum VFSVolumeRole: UInt8, Equatable {
    /// Boot-critical OS files. Ordinary VFS mutation is always denied, even to
    /// kernel callers; an authenticated updater must use a separate mechanism.
    case system = 1
    /// Durable user-created files and application state.
    case user = 2
    /// Volatile scratch data that is not promised across reboot.
    case temporary = 3
    /// Named kernel-mediated devices. This is never a raw-block escape hatch.
    case device = 4

    var isPersistent: Bool { self == .system || self == .user }
    var isOrdinaryMutableStorage: Bool { self == .user || self == .temporary }
}

struct VFSVolumeDescriptor: Equatable {
    let identifier: VFSVolumeIdentifier
    let role: VFSVolumeRole
    let visibility: VFSVolumeVisibility
}

struct VFSCapabilityIdentifier: RawRepresentable, Equatable {
    let rawValue: UInt64

    init?(rawValue: UInt64) {
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }
}

struct VFSAccessRights: RawRepresentable, Equatable {
    let rawValue: UInt16

    init?(rawValue: UInt16) {
        guard rawValue & ~Self.allKnownBits == 0 else { return nil }
        self.rawValue = rawValue
    }

    static let none = Self(rawValue: 0)!
    static let readData = Self(rawValue: 1 << 0)!
    static let writeData = Self(rawValue: 1 << 1)!
    static let enumerate = Self(rawValue: 1 << 2)!
    static let traverse = Self(rawValue: 1 << 3)!
    static let create = Self(rawValue: 1 << 4)!
    static let remove = Self(rawValue: 1 << 5)!
    static let readMetadata = Self(rawValue: 1 << 6)!
    static let writeMetadata = Self(rawValue: 1 << 7)!
    static let execute = Self(rawValue: 1 << 8)!

    static let all = Self(rawValue: allKnownBits)!

    func union(_ other: Self) -> Self {
        Self(rawValue: rawValue | other.rawValue)!
    }

    func contains(_ other: Self) -> Bool {
        rawValue & other.rawValue == other.rawValue
    }

    func isSubset(of other: Self) -> Bool {
        rawValue & ~other.rawValue == 0
    }

    var isEmpty: Bool { rawValue == 0 }

    fileprivate static let allKnownBits: UInt16 = (1 << 9) - 1
}

enum VFSRolePolicy {
    static func maximumAccess(for role: VFSVolumeRole) -> VFSAccessRights {
        switch role {
        case .system:
            return .readData.union(.enumerate).union(.traverse)
                .union(.readMetadata).union(.execute)
        case .user, .temporary:
            return .all
        case .device:
            return .readData.union(.writeData).union(.enumerate)
                .union(.traverse).union(.readMetadata)
        }
    }
}

enum VFSNodeKind: UInt8, Equatable {
    case regularFile = 1
    case directory = 2
    case symbolicLink = 3
    case device = 4
}

struct VFSTimestamp: Equatable {
    let secondsSinceUnixEpoch: Int64
    let nanoseconds: UInt32

    init?(secondsSinceUnixEpoch: Int64, nanoseconds: UInt32) {
        guard nanoseconds < 1_000_000_000 else { return nil }
        self.secondsSinceUnixEpoch = secondsSinceUnixEpoch
        self.nanoseconds = nanoseconds
    }
}

struct VFSNodeMetadata: Equatable {
    let identifier: VFSNodeIdentifier
    let kind: VFSNodeKind
    let byteCount: UInt64
    let linkCount: UInt32
    /// Changes whenever provider state that can invalidate caches changes.
    let generation: UInt64
    let createdAt: VFSTimestamp
    let modifiedAt: VFSTimestamp
    /// Provider-side ceiling. Mount and principal policy can only remove rights.
    let availableAccess: VFSAccessRights

    init?(
        identifier: VFSNodeIdentifier,
        kind: VFSNodeKind,
        byteCount: UInt64,
        linkCount: UInt32,
        generation: UInt64,
        createdAt: VFSTimestamp,
        modifiedAt: VFSTimestamp,
        availableAccess: VFSAccessRights
    ) {
        guard linkCount != 0, generation != 0,
              VFSNodeMetadata.rightsAreValid(availableAccess, for: kind)
        else { return nil }
        self.identifier = identifier
        self.kind = kind
        self.byteCount = byteCount
        self.linkCount = linkCount
        self.generation = generation
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.availableAccess = availableAccess
    }

    private static func rightsAreValid(
        _ rights: VFSAccessRights,
        for kind: VFSNodeKind
    ) -> Bool {
        let ceiling: VFSAccessRights
        switch kind {
        case .regularFile:
            ceiling = .readData.union(.writeData)
                .union(.readMetadata).union(.writeMetadata).union(.execute)
        case .directory:
            ceiling = .enumerate.union(.traverse).union(.create).union(.remove)
                .union(.readMetadata).union(.writeMetadata)
        case .symbolicLink:
            // This milestone exposes links to file managers as metadata but
            // intentionally does not follow them during path resolution.
            ceiling = .readMetadata.union(.writeMetadata)
        case .device:
            ceiling = .readData.union(.writeData).union(.readMetadata)
        }
        return rights.isSubset(of: ceiling)
    }
}

struct VFSDirectoryCookie: RawRepresentable, Equatable {
    let rawValue: UInt64
    static let start = Self(rawValue: 0)
}

struct VFSDirectoryEntry {
    let identifier: VFSNodeIdentifier
    let kind: VFSNodeKind
    let name: VFSNameView
}

enum VFSDirectoryReadResult {
    case entry(VFSDirectoryEntry, nextCookie: VFSDirectoryCookie)
    case end
    /// The directory changed and enumeration must restart at `.start`.
    case staleCookie
    case nameBufferTooSmall(requiredByteCount: Int)
    case failure(VFSProviderFailure)
}

enum VFSProviderFailure: UInt8, Equatable {
    case notFound = 1
    case notDirectory = 2
    case isDirectory = 3
    case alreadyExists = 4
    case noSpace = 5
    case readOnly = 6
    case invalidOffset = 7
    case corrupt = 8
    case unavailable = 9
    case ioFailure = 10
}

enum VFSLookupResult {
    case node(VFSNodeMetadata)
    case failure(VFSProviderFailure)
}

enum VFSMetadataResult {
    case metadata(VFSNodeMetadata)
    case failure(VFSProviderFailure)
}

enum VFSDataIOResult: Equatable {
    case transferred(byteCount: Int)
    case failure(VFSProviderFailure)
}

/// Kernel-internal provider boundary. A concrete filesystem translates its own
/// storage representation into stable node IDs. User tasks can reach providers
/// only through checked VFS handles and byte-range operations.
protocol VFSNodeProvider {
    var volumeIdentifier: VFSVolumeIdentifier { get }

    mutating func metadata(for node: VFSNodeIdentifier) -> VFSMetadataResult

    mutating func lookup(
        parent: VFSNodeIdentifier,
        name: VFSNameView
    ) -> VFSLookupResult

    mutating func readDirectory(
        node: VFSNodeIdentifier,
        after cookie: VFSDirectoryCookie,
        nameOutput: UnsafeMutableRawBufferPointer
    ) -> VFSDirectoryReadResult

    mutating func read(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        into output: UnsafeMutableRawBufferPointer
    ) -> VFSDataIOResult

    mutating func write(
        node: VFSNodeIdentifier,
        at offset: UInt64,
        from input: UnsafeRawBufferPointer
    ) -> VFSDataIOResult
}
