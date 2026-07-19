/// A copied file name owned by a FileBrowserModel name arena. The view remains
/// valid until that model begins another directory reload.
struct FileBrowserNameView {
    private let bytes: UnsafePointer<UInt8>
    let byteCount: Int

    fileprivate init(bytes: UnsafePointer<UInt8>, byteCount: Int) {
        self.bytes = bytes
        self.byteCount = byteCount
    }

    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < byteCount else { return nil }
        return bytes[index]
    }
}

struct FileBrowserItemView {
    let identifier: VFSNodeIdentifier
    let kind: VFSNodeKind
    let byteCount: UInt64
    let metadataGeneration: UInt64
    let name: FileBrowserNameView
}

/// Caller-owned entry storage. Vacant values are exposed so boot code can
/// construct a fixed-capacity buffer without a heap or fake VFS identifiers.
struct FileBrowserEntryRecord {
    fileprivate var identifier: VFSNodeIdentifier?
    fileprivate var kind: VFSNodeKind
    fileprivate var byteCount: UInt64
    fileprivate var metadataGeneration: UInt64
    fileprivate var nameOffset: Int
    fileprivate var nameByteCount: Int

    static let vacant = FileBrowserEntryRecord(
        identifier: nil,
        kind: .regularFile,
        byteCount: 0,
        metadataGeneration: 0,
        nameOffset: 0,
        nameByteCount: 0
    )
}

enum FileBrowserAppendRejection: Equatable {
    case entryCapacityExhausted
    case nameCapacityExhausted(requiredByteCount: Int, availableByteCount: Int)
    case duplicateIdentifier
    case duplicateName
    case metadataDoesNotMatchEntry
}

enum FileBrowserAppendResult: Equatable {
    case inserted(index: Int)
    case rejected(FileBrowserAppendRejection)
}

enum FileBrowserSelectionCommand: Equatable {
    case previous
    case next
    case first
    case last
    case pagePrevious
    case pageNext
}

enum FileBrowserSelectionResult: Equatable {
    case changed(index: Int)
    case unchanged(index: Int)
    case empty
}

/// Deterministic, allocation-free directory state for a file-manager view.
///
/// Entry records and copied UTF-8 names are owned by the caller. The model
/// keeps directories before other node kinds, then orders names bytewise. That
/// deliberately avoids locale or Unicode normalization policy in the kernel.
/// External serialization is required if more than one CPU mutates a model.
struct FileBrowserModel {
    private let entries: UnsafeMutableBufferPointer<FileBrowserEntryRecord>
    private let nameStorage: UnsafeMutableRawBufferPointer
    let visibleRowCapacity: Int

    private(set) var count = 0
    private(set) var usedNameByteCount = 0
    private(set) var firstVisibleIndex = 0
    private(set) var selectedIndex: Int?
    private(set) var revision: UInt64 = 1

    init?(
        entryStorage: UnsafeMutableBufferPointer<FileBrowserEntryRecord>,
        nameStorage: UnsafeMutableRawBufferPointer,
        visibleRowCapacity: Int
    ) {
        guard entryStorage.baseAddress != nil,
              !entryStorage.isEmpty,
              nameStorage.baseAddress != nil,
              !nameStorage.isEmpty,
              visibleRowCapacity > 0,
              visibleRowCapacity <= entryStorage.count
        else {
            return nil
        }
        entries = entryStorage
        self.nameStorage = nameStorage
        self.visibleRowCapacity = visibleRowCapacity
        clearRecords()
    }

    var capacity: Int { entries.count }

    var visibleItemCount: Int {
        let remaining = count - firstVisibleIndex
        return remaining < visibleRowCapacity
            ? remaining
            : visibleRowCapacity
    }

    var selectedItem: FileBrowserItemView? {
        guard let selectedIndex else { return nil }
        return item(at: selectedIndex)
    }

    /// Invalidates borrowed item/name views. Revision exhaustion fails closed
    /// and leaves the current listing intact.
    mutating func beginReload() -> Bool {
        guard revision != UInt64.max else { return false }
        revision += 1
        count = 0
        usedNameByteCount = 0
        firstVisibleIndex = 0
        selectedIndex = nil
        clearRecords()
        return true
    }

    mutating func append(
        _ directoryEntry: VFSDirectoryEntry,
        metadata: VFSNodeMetadata? = nil
    ) -> FileBrowserAppendResult {
        guard count < entries.count else {
            return .rejected(.entryCapacityExhausted)
        }
        if let metadata,
           metadata.identifier != directoryEntry.identifier
            || metadata.kind != directoryEntry.kind {
            return .rejected(.metadataDoesNotMatchEntry)
        }

        var index = 0
        while index < count {
            let existing = entries[index]
            if existing.identifier == directoryEntry.identifier {
                return .rejected(.duplicateIdentifier)
            }
            if namesAreEqual(existing, directoryEntry.name) {
                return .rejected(.duplicateName)
            }
            index += 1
        }

        let requiredNameBytes = directoryEntry.name.byteCount
        guard requiredNameBytes <= nameStorage.count - usedNameByteCount else {
            return .rejected(
                .nameCapacityExhausted(
                    requiredByteCount: requiredNameBytes,
                    availableByteCount: nameStorage.count - usedNameByteCount
                )
            )
        }
        let nameOffset = usedNameByteCount
        var nameIndex = 0
        while nameIndex < requiredNameBytes {
            guard let byte = directoryEntry.name.byte(at: nameIndex) else {
                return .rejected(.metadataDoesNotMatchEntry)
            }
            nameStorage[nameOffset + nameIndex] = byte
            nameIndex += 1
        }
        let record = FileBrowserEntryRecord(
            identifier: directoryEntry.identifier,
            kind: directoryEntry.kind,
            byteCount: metadata?.byteCount ?? 0,
            metadataGeneration: metadata?.generation ?? 0,
            nameOffset: nameOffset,
            nameByteCount: requiredNameBytes
        )

        let insertionIndex = insertionIndex(for: record)
        var destination = count
        while destination > insertionIndex {
            entries[destination] = entries[destination - 1]
            destination -= 1
        }
        entries[insertionIndex] = record
        count += 1
        usedNameByteCount += requiredNameBytes

        if let selectedIndex {
            if insertionIndex <= selectedIndex {
                self.selectedIndex = selectedIndex + 1
            }
        } else {
            selectedIndex = 0
        }
        ensureSelectionIsVisible()
        return .inserted(index: insertionIndex)
    }

    func item(at index: Int) -> FileBrowserItemView? {
        guard index >= 0, index < count,
              let identifier = entries[index].identifier,
              let base = nameStorage.baseAddress?
                .assumingMemoryBound(to: UInt8.self)
        else {
            return nil
        }
        let record = entries[index]
        return FileBrowserItemView(
            identifier: identifier,
            kind: record.kind,
            byteCount: record.byteCount,
            metadataGeneration: record.metadataGeneration,
            name: FileBrowserNameView(
                bytes: UnsafePointer(base + record.nameOffset),
                byteCount: record.nameByteCount
            )
        )
    }

    func visibleItem(atRow row: Int) -> FileBrowserItemView? {
        guard row >= 0, row < visibleItemCount else { return nil }
        return item(at: firstVisibleIndex + row)
    }

    mutating func select(index: Int) -> FileBrowserSelectionResult {
        guard count > 0 else { return .empty }
        guard index >= 0, index < count else {
            return .unchanged(index: selectedIndex ?? 0)
        }
        if selectedIndex == index {
            return .unchanged(index: index)
        }
        selectedIndex = index
        ensureSelectionIsVisible()
        return .changed(index: index)
    }

    mutating func moveSelection(
        _ command: FileBrowserSelectionCommand
    ) -> FileBrowserSelectionResult {
        guard count > 0 else { return .empty }
        let current = selectedIndex ?? 0
        let requested: Int
        switch command {
        case .previous:
            requested = current > 0 ? current - 1 : 0
        case .next:
            requested = current + 1 < count ? current + 1 : count - 1
        case .first:
            requested = 0
        case .last:
            requested = count - 1
        case .pagePrevious:
            requested = current > visibleRowCapacity
                ? current - visibleRowCapacity
                : 0
        case .pageNext:
            let distance = count - 1 - current
            requested = distance > visibleRowCapacity
                ? current + visibleRowCapacity
                : count - 1
        }
        return select(index: requested)
    }

    mutating func scroll(byRows delta: Int) -> Bool {
        let maximumFirst = count > visibleRowCapacity
            ? count - visibleRowCapacity
            : 0
        let previous = firstVisibleIndex
        if delta >= 0 {
            let remaining = maximumFirst - firstVisibleIndex
            firstVisibleIndex = delta >= remaining
                ? maximumFirst
                : firstVisibleIndex + delta
        } else {
            let magnitude = delta == Int.min ? Int.max : -delta
            firstVisibleIndex = magnitude >= firstVisibleIndex
                ? 0
                : firstVisibleIndex - magnitude
        }
        return firstVisibleIndex != previous
    }

    /// ASCII-case-insensitive type-ahead matching. Non-ASCII bytes are
    /// compared exactly, preserving the VFS byte-oriented naming contract.
    mutating func selectFirstName(
        matchingPrefix prefix: UnsafeRawBufferPointer
    ) -> FileBrowserSelectionResult {
        guard count > 0 else { return .empty }
        guard prefix.count > 0, prefix.baseAddress != nil else {
            return .unchanged(index: selectedIndex ?? 0)
        }
        var index = 0
        while index < count {
            if record(entries[index], hasPrefix: prefix) {
                return select(index: index)
            }
            index += 1
        }
        return .unchanged(index: selectedIndex ?? 0)
    }

    private mutating func ensureSelectionIsVisible() {
        guard let selectedIndex else { return }
        if selectedIndex < firstVisibleIndex {
            firstVisibleIndex = selectedIndex
        } else if selectedIndex >= firstVisibleIndex + visibleRowCapacity {
            firstVisibleIndex = selectedIndex - visibleRowCapacity + 1
        }
    }

    private func insertionIndex(for candidate: FileBrowserEntryRecord) -> Int {
        var index = 0
        while index < count {
            if comesBefore(candidate, entries[index]) { return index }
            index += 1
        }
        return count
    }

    private func comesBefore(
        _ first: FileBrowserEntryRecord,
        _ second: FileBrowserEntryRecord
    ) -> Bool {
        let firstDirectory = first.kind == .directory
        let secondDirectory = second.kind == .directory
        if firstDirectory != secondDirectory { return firstDirectory }

        let commonCount = first.nameByteCount < second.nameByteCount
            ? first.nameByteCount
            : second.nameByteCount
        var offset = 0
        while offset < commonCount {
            let firstByte = nameStorage[first.nameOffset + offset]
            let secondByte = nameStorage[second.nameOffset + offset]
            if firstByte != secondByte { return firstByte < secondByte }
            offset += 1
        }
        if first.nameByteCount != second.nameByteCount {
            return first.nameByteCount < second.nameByteCount
        }
        return (first.identifier?.localValue ?? 0)
            < (second.identifier?.localValue ?? 0)
    }

    private func namesAreEqual(
        _ existing: FileBrowserEntryRecord,
        _ candidate: VFSNameView
    ) -> Bool {
        guard existing.nameByteCount == candidate.byteCount else {
            return false
        }
        var index = 0
        while index < existing.nameByteCount {
            guard let candidateByte = candidate.byte(at: index),
                  nameStorage[existing.nameOffset + index] == candidateByte
            else {
                return false
            }
            index += 1
        }
        return true
    }

    private func record(
        _ existing: FileBrowserEntryRecord,
        hasPrefix prefix: UnsafeRawBufferPointer
    ) -> Bool {
        guard prefix.count <= existing.nameByteCount else { return false }
        var index = 0
        while index < prefix.count {
            let stored = foldedASCII(nameStorage[existing.nameOffset + index])
            let requested = foldedASCII(prefix[index])
            if stored != requested { return false }
            index += 1
        }
        return true
    }

    private func foldedASCII(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5a ? byte + 0x20 : byte
    }

    private mutating func clearRecords() {
        var index = 0
        while index < entries.count {
            entries[index] = .vacant
            index += 1
        }
    }
}
