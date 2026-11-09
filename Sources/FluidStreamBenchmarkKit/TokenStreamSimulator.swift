/// Settings for a simulated LLM response stream.
public struct TokenStreamConfiguration: Sendable, Equatable {
    /// The model's steady generation rate.
    public var tokensPerSecond: Double
    public var tokenCount: Int
    /// When `false`, each token arrives on its own at an exact cadence: the best case for
    /// the network.
    public var jitterEnabled: Bool
    /// The time between network packets, in seconds. Each packet carries every token
    /// generated since the previous one.
    public var packetInterval: ClosedRange<Double>
    /// The chance, per packet, of an extra stall (for example a congested cell link).
    public var stallProbability: Double
    public var stallDuration: ClosedRange<Double>
    public var seed: UInt64
    public var corpus: String

    public init(
        tokensPerSecond: Double = 150,
        tokenCount: Int = 6_000,
        jitterEnabled: Bool = true,
        packetInterval: ClosedRange<Double> = 0.015...0.120,
        stallProbability: Double = 0.02,
        stallDuration: ClosedRange<Double> = 0.2...0.6,
        seed: UInt64 = 42,
        corpus: String = BenchmarkCorpus.mixedAnswer
    ) {
        precondition(tokensPerSecond > 0 && tokenCount > 0)
        precondition(packetInterval.lowerBound > 0 && (0...1).contains(stallProbability))
        self.tokensPerSecond = tokensPerSecond
        self.tokenCount = tokenCount
        self.jitterEnabled = jitterEnabled
        self.packetInterval = packetInterval
        self.stallProbability = stallProbability
        self.stallDuration = stallDuration
        self.seed = seed
        self.corpus = corpus
    }
}

/// One network delivery: everything that arrived in a single read.
public struct StreamPacket: Sendable, Equatable {
    /// Seconds since the start of the stream.
    public let time: Double
    public let text: String
    public let tokenCount: Int
}

/// Turns a configuration into a fixed, reproducible packet schedule.
///
/// The model emits token *i* at `i / tokensPerSecond`. The network wakes at jittered
/// intervals and delivers everything generated so far. So the average rate matches the
/// model, but arrivals are bursty, which is the condition `FluidStreamCore` exists to smooth.
public struct TokenStreamSimulator: Sendable {
    public let configuration: TokenStreamConfiguration

    public init(_ configuration: TokenStreamConfiguration = TokenStreamConfiguration()) {
        self.configuration = configuration
    }

    /// The tokens in delivery order. The corpus repeats until `tokenCount` is reached.
    public func tokens() -> [String] {
        let base = Tokenizer.tokens(configuration.corpus)
        precondition(!base.isEmpty, "corpus is empty")
        return (0..<configuration.tokenCount).map { base[$0 % base.count] }
    }

    public func schedule() -> [StreamPacket] {
        let tokens = tokens()
        let rate = configuration.tokensPerSecond

        guard configuration.jitterEnabled else {
            return tokens.enumerated().map { i, token in
                StreamPacket(time: Double(i + 1) / rate, text: token, tokenCount: 1)
            }
        }

        var rng = SplitMix64(seed: configuration.seed)
        var packets: [StreamPacket] = []
        var time = 0.0
        var delivered = 0
        while delivered < tokens.count {
            time += rng.uniform(in: configuration.packetInterval)
            if rng.uniform(in: 0...1) < configuration.stallProbability {
                time += rng.uniform(in: configuration.stallDuration)
            }
            let generated = min(tokens.count, Int((time * rate).rounded(.down)))
            guard generated > delivered else { continue }
            packets.append(StreamPacket(
                time: time,
                text: tokens[delivered..<generated].joined(),
                tokenCount: generated - delivered
            ))
            delivered = generated
        }
        return packets
    }
}

/// Plays a schedule in real time.
public struct SchedulePlayer: Sendable {
    public let packets: [StreamPacket]

    public init(_ packets: [StreamPacket]) {
        self.packets = packets
    }

    /// Delivers each packet at its scheduled time. Throws `CancellationError` if the task is cancelled.
    public func play<C: Clock<Duration>>(
        clock: C = ContinuousClock(),
        deliver: (StreamPacket) async throws -> Void
    ) async throws {
        let start = clock.now
        for packet in packets {
            try await clock.sleep(until: start.advanced(by: .seconds(packet.time)), tolerance: nil)
            try await deliver(packet)
        }
    }
}

/// An approximate BPE tokenizer: a word plus its trailing whitespace, with words longer
/// than 5 characters cut into 4-character pieces. Real tokens average about 4 characters,
/// and cutting this way splits tags such as `<thinking>` across tokens, just like real streams.
public enum Tokenizer {
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word: [Character] = []
        var trailing = ""

        func flush() {
            guard !word.isEmpty || !trailing.isEmpty else { return }
            if word.count > 5 {
                var i = 0
                while i < word.count {
                    tokens.append(String(word[i..<min(i + 4, word.count)]))
                    i += 4
                }
                tokens[tokens.count - 1] += trailing
            } else {
                tokens.append(String(word) + trailing)
            }
            word.removeAll(keepingCapacity: true)
            trailing = ""
        }

        for character in text {
            if character.isWhitespace {
                trailing.append(character)
            } else {
                if !trailing.isEmpty { flush() }
                word.append(character)
            }
        }
        flush()
        return tokens
    }
}

/// A small, fast, seedable generator, so schedules are reproducible across runs and devices.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * 0x1p-53
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
