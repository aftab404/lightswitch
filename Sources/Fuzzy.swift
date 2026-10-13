/// fzf-style fuzzy matching: the pattern must appear as a subsequence of the text; matches at word
/// starts and consecutive runs score higher, gaps score lower. Finds the best alignment, not just the first.
enum Fuzzy {
    struct Match {
        var score: Int
        var positions: [Int]
    }

    private static let matchScore = 16
    private static let gapStart = 3
    private static let gapExtend = 1
    private static let consecutiveBonus = 4
    private static let firstCharMultiplier = 2

    /// Case- and accent-insensitive form of a character ("Ü" → "u"). Always one character in, one out,
    /// so match positions line up with the original text.
    static func normalized(_ character: Character) -> Character {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).first ?? character
    }

    /// Text prepared for matching once, for lists searched on every keystroke (a few hundred browser tabs).
    struct Text {
        let normalized: [Character]
        let bonus: [Int]

        init(_ characters: [Character]) {
            normalized = characters.map(Fuzzy.normalized)
            bonus = characters.indices.map { Fuzzy.boundaryBonus(characters, $0) }
        }
    }

    static func match(_ pattern: [Character], in text: [Character]) -> Match? {
        match(pattern, in: Text(text))
    }

    static func match(_ pattern: [Character], in text: Text) -> Match? {
        let n = text.normalized.count, m = pattern.count
        guard m > 0 else { return Match(score: 0, positions: []) }
        guard m <= n else { return nil }

        let pattern = pattern.map(normalized)
        let lower = text.normalized
        var k = 0
        for c in lower where k < m && c == pattern[k] { k += 1 }
        guard k == m else { return nil }

        let bonus = text.bonus
        let none = Int.min / 2
        // score[i][j]: best score with pattern[i] matched at text[j]; back[i][j]: where pattern[i-1] matched.
        var score = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var back = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)

        for j in 0..<n where lower[j] == pattern[0] {
            score[0][j] = matchScore + bonus[j] * firstCharMultiplier
        }
        if m > 1 {
            for i in 1..<m {
                // Best score[i-1][k] - gap penalty over k <= j-2, maintained as j advances.
                var gapBest = none, gapFrom = -1
                for j in i..<n {
                    if j >= 2 {
                        if gapBest != none { gapBest -= gapExtend }
                        let prev = score[i - 1][j - 2]
                        if prev != none, prev - gapStart > gapBest {
                            gapBest = prev - gapStart
                            gapFrom = j - 2
                        }
                    }
                    guard lower[j] == pattern[i] else { continue }
                    if score[i - 1][j - 1] != none {
                        score[i][j] = score[i - 1][j - 1] + matchScore + max(bonus[j], consecutiveBonus)
                        back[i][j] = j - 1
                    }
                    if gapBest != none, gapBest + matchScore + bonus[j] > score[i][j] {
                        score[i][j] = gapBest + matchScore + bonus[j]
                        back[i][j] = gapFrom
                    }
                }
            }
        }

        var best = none, end = -1
        for j in 0..<n where score[m - 1][j] > best {
            best = score[m - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var j = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = back[i][j]
        }
        return Match(score: best, positions: positions)
    }

    /// Where `pattern` appears unbroken in `text`, scored the way `match` scores such a run. For text like web
    /// addresses, where a few letters scattered through a long path would match almost anything.
    /// `allowedStart` can rule out runs starting at some positions.
    static func substringMatch(_ pattern: [Character], in text: Text, allowedStart: (Int) -> Bool = { _ in true }) -> Match? {
        let n = text.normalized.count, m = pattern.count
        guard m > 0 else { return Match(score: 0, positions: []) }
        guard m <= n else { return nil }

        let pattern = pattern.map(normalized)
        var best: Match?
        for start in 0...(n - m) where text.normalized[start] == pattern[0] && allowedStart(start) {
            guard (1..<m).allSatisfy({ text.normalized[start + $0] == pattern[$0] }) else { continue }
            var score = matchScore + text.bonus[start] * firstCharMultiplier
            for j in start + 1 ..< start + m {
                score += matchScore + max(text.bonus[j], consecutiveBonus)
            }
            if score > best?.score ?? Int.min {
                best = Match(score: score, positions: Array(start ..< start + m))
            }
        }
        return best
    }

    private static func boundaryBonus(_ text: [Character], _ j: Int) -> Int {
        guard j > 0 else { return 10 }
        let prev = text[j - 1], cur = text[j]
        if prev.isWhitespace { return 10 }
        if "/\\-_.:|·—–()[],".contains(prev) { return 9 }
        if prev.isLowercase && cur.isUppercase { return 7 }
        if !prev.isNumber && cur.isNumber { return 7 }
        return 0
    }
}
