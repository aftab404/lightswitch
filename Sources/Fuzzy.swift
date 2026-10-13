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

    /// `pattern` must already be lowercased.
    static func match(_ pattern: [Character], in text: [Character]) -> Match? {
        let n = text.count, m = pattern.count
        guard m > 0 else { return Match(score: 0, positions: []) }
        guard m <= n else { return nil }

        let lower = text.map { String($0).lowercased().first ?? $0 }
        var k = 0
        for c in lower where k < m && c == pattern[k] { k += 1 }
        guard k == m else { return nil }

        let bonus = (0..<n).map { boundaryBonus(text, $0) }
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
