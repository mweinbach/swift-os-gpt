enum ThreadExecutionState: UInt8, Equatable {
    case vacant
    case ready
    case running
    case blocked
    case exited
}

struct ScheduledThread: Equatable {
    let identifier: UInt32
    let processIdentifier: UInt32
    var state: ThreadExecutionState
    let affinityMask: UInt64
    let contextAddress: UInt64
    var switchCount: UInt64

    static let vacant = ScheduledThread(
        identifier: 0,
        processIdentifier: 0,
        state: .vacant,
        affinityMask: 0,
        contextAddress: 0,
        switchCount: 0
    )
}

struct SchedulingDecision: Equatable {
    let previousThreadIdentifier: UInt32?
    let nextThreadIdentifier: UInt32
    let nextContextAddress: UInt64
}

/// Fixed-capacity round-robin policy. Storage belongs to the kernel so the
/// scheduler has no allocator dependency and can be used from a timer IRQ.
struct RunQueue {
    private var threads: UnsafeMutableBufferPointer<ScheduledThread>
    private var currentIndices: UnsafeMutableBufferPointer<Int32>
    private(set) var threadCount: Int = 0

    init?(
        threadStorage: UnsafeMutableBufferPointer<ScheduledThread>,
        currentIndexStorage: UnsafeMutableBufferPointer<Int32>,
        processorCount: Int
    ) {
        guard !threadStorage.isEmpty,
              processorCount > 0,
              processorCount <= currentIndexStorage.count,
              processorCount <= 64
        else {
            return nil
        }
        threads = threadStorage
        currentIndices = UnsafeMutableBufferPointer(
            rebasing: currentIndexStorage.prefix(processorCount)
        )
        var index = 0
        while index < threads.count {
            threads[index] = .vacant
            index += 1
        }
        index = 0
        while index < currentIndices.count {
            currentIndices[index] = -1
            index += 1
        }
    }

    var capacity: Int { threads.count }
    var processorCount: Int { currentIndices.count }

    func thread(at index: Int) -> ScheduledThread? {
        guard index >= 0, index < threadCount else { return nil }
        return threads[index]
    }

    func thread(identifier: UInt32) -> ScheduledThread? {
        guard let index = index(of: identifier) else { return nil }
        return threads[index]
    }

    @discardableResult
    mutating func add(
        identifier: UInt32,
        processIdentifier: UInt32,
        affinityMask: UInt64,
        contextAddress: UInt64
    ) -> Bool {
        let usableProcessorMask = processorCount == 64
            ? UInt64.max
            : (UInt64(1) << UInt64(processorCount)) - 1
        guard identifier != 0,
              processIdentifier != 0,
              affinityMask & usableProcessorMask != 0,
              contextAddress != 0,
              contextAddress & 0xf == 0,
              threadCount < threads.count,
              index(of: identifier) == nil
        else {
            return false
        }
        threads[threadCount] = ScheduledThread(
            identifier: identifier,
            processIdentifier: processIdentifier,
            state: .ready,
            affinityMask: affinityMask,
            contextAddress: contextAddress,
            switchCount: 0
        )
        threadCount += 1
        return true
    }

    mutating func begin(on processor: Int) -> SchedulingDecision? {
        guard validProcessor(processor), currentIndices[processor] < 0,
              let nextIndex = nextReadyIndex(after: -1, on: processor)
        else {
            return nil
        }
        return select(nextIndex, replacing: nil, on: processor)
    }

    mutating func preempt(on processor: Int) -> SchedulingDecision? {
        guard validProcessor(processor) else { return nil }
        let rawCurrent = currentIndices[processor]
        guard rawCurrent >= 0 else { return begin(on: processor) }
        let current = Int(rawCurrent)
        guard current < threadCount, threads[current].state == .running else {
            return nil
        }

        threads[current].state = .ready
        guard let next = nextReadyIndex(after: current, on: processor) else {
            threads[current].state = .running
            return nil
        }
        return select(next, replacing: current, on: processor)
    }

    @discardableResult
    mutating func blockCurrent(on processor: Int) -> SchedulingDecision? {
        transitionCurrent(to: .blocked, on: processor)
    }

    @discardableResult
    mutating func exitCurrent(on processor: Int) -> SchedulingDecision? {
        transitionCurrent(to: .exited, on: processor)
    }

    @discardableResult
    mutating func wake(identifier: UInt32) -> Bool {
        guard let index = index(of: identifier),
              threads[index].state == .blocked
        else {
            return false
        }
        threads[index].state = .ready
        return true
    }

    private mutating func transitionCurrent(
        to state: ThreadExecutionState,
        on processor: Int
    ) -> SchedulingDecision? {
        guard state == .blocked || state == .exited,
              validProcessor(processor),
              currentIndices[processor] >= 0
        else {
            return nil
        }
        let current = Int(currentIndices[processor])
        guard current < threadCount, threads[current].state == .running else {
            return nil
        }
        threads[current].state = state
        currentIndices[processor] = -1
        guard let next = nextReadyIndex(after: current, on: processor) else {
            return nil
        }
        return select(next, replacing: current, on: processor)
    }

    private mutating func select(
        _ nextIndex: Int,
        replacing previousIndex: Int?,
        on processor: Int
    ) -> SchedulingDecision {
        threads[nextIndex].state = .running
        threads[nextIndex].switchCount &+= 1
        currentIndices[processor] = Int32(nextIndex)
        return SchedulingDecision(
            previousThreadIdentifier: previousIndex.map {
                threads[$0].identifier
            },
            nextThreadIdentifier: threads[nextIndex].identifier,
            nextContextAddress: threads[nextIndex].contextAddress
        )
    }

    private func nextReadyIndex(after current: Int, on processor: Int) -> Int? {
        guard threadCount > 0 else { return nil }
        var offset = 1
        while offset <= threadCount {
            let candidate = (current + offset) % threadCount
            let thread = threads[candidate]
            if thread.state == .ready,
               thread.affinityMask & (UInt64(1) << UInt64(processor)) != 0 {
                return candidate
            }
            offset += 1
        }
        return nil
    }

    private func index(of identifier: UInt32) -> Int? {
        var index = 0
        while index < threadCount {
            if threads[index].identifier == identifier { return index }
            index += 1
        }
        return nil
    }

    private func validProcessor(_ processor: Int) -> Bool {
        processor >= 0 && processor < currentIndices.count
    }
}
