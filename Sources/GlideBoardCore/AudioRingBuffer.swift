import Foundation

enum AudioRingBufferError: Error, Equatable {
    case invalidRange
    case samplesOverwritten
    case samplesNotYetAvailable
}

struct AudioRingBuffer: Sendable {
    let capacity: Int
    private var storage: [Float]
    private(set) var nextSample: Int64 = 0
    private var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: 0, count: capacity)
    }

    var availableRange: Range<Int64> {
        (nextSample - Int64(count))..<nextSample
    }

    mutating func append(_ samples: [Float]) {
        for sample in samples {
            storage[Int(nextSample % Int64(capacity))] = sample
            nextSample += 1
            count = min(capacity, count + 1)
        }
    }

    func samples(in range: Range<Int64>) throws -> [Float] {
        guard range.lowerBound <= range.upperBound else {
            throw AudioRingBufferError.invalidRange
        }
        guard range.lowerBound >= availableRange.lowerBound else {
            throw AudioRingBufferError.samplesOverwritten
        }
        guard range.upperBound <= availableRange.upperBound else {
            throw AudioRingBufferError.samplesNotYetAvailable
        }
        return range.map { storage[Int($0 % Int64(capacity))] }
    }

    mutating func reset(origin: Int64? = nil) {
        storage = Array(repeating: 0, count: capacity)
        count = 0
        if let origin { nextSample = origin }
    }
}
