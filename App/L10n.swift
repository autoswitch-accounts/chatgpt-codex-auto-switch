import AppKit

// MARK: - 界面语言
//
// 中文原文就是键：英文译文在 App/en.lproj/Localizable.strings（带数量的在 .stringsdict），中文界面直接用键本身。
// Text("…") / Button("…") / Label("…") 这类字面量自己会查表；
// 先拼成 String 再交给 Text、或传给参数是 String 的组件（SettingRow、StatusChip、say…）的，要先过 L(…)。
// 改完界面文字跑 scripts/i18n_check.py，看有没有漏翻、漏包的。

/// 按当前界面语言取一句话；插值照常写：L("已切到 \(email)")
func L(_ s: String.LocalizationValue) -> String { String(localized: s) }

/// 同一个中文词英文要两种说法时用：键写成「中文#用途」（如「账号#列」），中文界面显示 zh。
/// 例：「账号」做页名是 Accounts，做表头是 Account
func L(_ key: StaticString, zh: String.LocalizationValue) -> String { String(localized: key, defaultValue: zh) }

/// 跟随系统 / 中文 / English：写进本 App 自己的 AppleLanguages，下次打开生效
enum AppLanguage {
    static let key = "AppleLanguages"

    /// 设置页里选的："system" / "zh" / "en"
    static var choice: String {
        get {
            let l = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String]
            guard let first = l?.first else { return "system" }
            return first.hasPrefix("en") ? "en" : "zh"
        }
        set {
            if newValue == "system" { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set([newValue == "en" ? "en" : "zh-Hans"], forKey: key) }
        }
    }

    /// 这次启动实际用的语言："en" / "zh"。也同步给 engine.py / autoswitch.py（autoswitch.json 的 lang）
    static let active: String = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "zh"

    /// 选的和这次启动用的不一样（要重开 App 才生效）
    static var pendingRestart: Bool {
        let c = choice
        if c == "system" {
            let sys = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: Locale.preferredLanguages)
            return (sys.first?.hasPrefix("en") == true ? "en" : "zh") != active
        }
        return c != active
    }

    /// 重开本 App。演示模式不重开：重开后的进程拿不到假数据的 HOME，会读到真实数据
    static var canRelaunch: Bool { ProcessInfo.processInfo.environment["CGA_DEMO"] != "1" }

    /// 先退出、再打开：交给一个小脚本等这个进程真的退了再 open，不会同时开着两个
    static func relaunch() {
        guard canRelaunch else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
        // terminate 被拦下（比如开着弹窗）时它会直接返回：照样退出，脚本随后把新的打开
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }
}

// MARK: - 以前写下的消息、日志换成当前语言
//
// 后台写进 notices.json、*.log 的是写入那一刻的语言。换语言后，用 engine.py / autoswitch.py 的
// 中英对照表（engine.py --phrases-json）把整句认出来，再按当前语言重写；认不出的原样显示。
final class PhraseBook: @unchecked Sendable {
    static let shared = PhraseBook()

    private struct Rule {
        let re: NSRegularExpression
        let names: [String]        // 每个捕获组对应的占位符名
        let out: [Piece]           // 目标语言的句子
        let hint: String           // 原句里最长的一段固定文字：先用它粗筛
        let prefix: Bool           // 只认句首（两句拼在一起写的日志）
    }
    private enum Piece { case text(String), slot(String) }

    private let lock = NSLock()
    private var loaded = false
    private var rules: [Rule] = []
    private var byChar: [Character: [Int]] = [:]     // 固定文字的首字 → 规则下标（规则按具体程度排好）
    private var cache: [String: String] = [:]

    /// 第一次用到时读对照表
    private func load() {
        if loaded { return }
        loaded = true
        struct P: Decodable { let pairs: [String: String] }
        let out = Store.exec("engine.py", ["--phrases-json"])
        guard let d = out.data(using: .utf8), let p = try? JSONDecoder().decode(P.self, from: d) else { return }
        let toEN = AppLanguage.active == "en"
        var r: [Rule] = []
        for (zh, en) in p.pairs where zh != en {
            let (src, dst) = toEN ? (zh, en) : (en, zh)
            r += PhraseBook.makeRules(src, dst)
        }
        rules = r.sorted { ($0.prefix ? 1 : 0, -$0.hint.count) < ($1.prefix ? 1 : 0, -$1.hint.count) }
        for (i, x) in rules.enumerated() { byChar[x.hint.first!, default: []].append(i) }
    }

    /// 按当前语言重写一句；认不出就原样返回
    func apply(_ s: String) -> String {
        lock.lock(); defer { lock.unlock() }
        load()
        if let c = cache[s] { return c }
        let r = translate(s, depth: 0)
        if cache.count > 20_000 { cache.removeAll() }
        cache[s] = r
        return r
    }

    private func translate(_ s: String, depth: Int) -> String {
        guard depth < 3, !s.isEmpty, needs(s) else { return s }
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        let cands = Set(s).flatMap { byChar[$0] ?? [] }.sorted()
        for i in cands {
            let r = rules[i]
            guard ns.range(of: r.hint).location != NSNotFound, let m = r.re.firstMatch(in: s, range: all) else { continue }
            let head = render(r, m, ns, depth)
            if !r.prefix { return head }
            return head + translate(ns.substring(from: m.range.location + m.range.length), depth: depth + 1)
        }
        return s
    }

    /// 要不要翻：目标是英文看有没有中文，目标是中文看有没有英文字母
    private func needs(_ s: String) -> Bool {
        let pattern = AppLanguage.active == "en" ? "[\\x{4e00}-\\x{9fff}]" : "[A-Za-z]"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    private func render(_ r: Rule, _ m: NSTextCheckingResult, _ ns: NSString, _ depth: Int) -> String {
        var vals: [String: String] = [:]
        for (i, n) in r.names.enumerated() where vals[n] == nil {
            let g = m.range(at: i + 1)
            if g.location != NSNotFound { vals[n] = translate(ns.substring(with: g), depth: depth + 1) }
        }
        return r.out.map { p -> String in
            switch p {
            case .text(let t): return t
            case .slot(let n): return vals[n] ?? "{\(n)}"
            }
        }.joined()
    }

    /// Python 的 format 句子拆成固定文字和 {占位符}（{{ }} 是字面的花括号）
    private static func pieces(_ t: String) -> [Piece] {
        var out: [Piece] = [], buf = "", i = t.startIndex
        while i < t.endIndex {
            let c = t[i], next = t.index(after: i)
            if (c == "{" || c == "}"), next < t.endIndex, t[next] == c { buf.append(c); i = t.index(after: next); continue }
            if c == "{", let close = t[next...].firstIndex(of: "}") {
                if !buf.isEmpty { out.append(.text(buf)); buf = "" }
                out.append(.slot(String(t[next..<close].split(separator: ":", maxSplits: 1).first ?? "")))
                i = t.index(after: close); continue
            }
            buf.append(c); i = next
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }

    private static func makeRules(_ src: String, _ dst: String) -> [Rule] {
        let ps = pieces(src)
        let hint = ps.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.max { $0.count < $1.count } ?? ""
        guard hint.count >= 2 else { return [] }        // 只有占位符或一两个标点的句子太宽泛，不认
        var pat = "", names: [String] = []
        for p in ps {
            switch p {
            case .text(let t): pat += NSRegularExpression.escapedPattern(for: t)
            case .slot(let n): pat += "(.+?)"; names.append(n)
            }
        }
        let out = pieces(dst)
        var r: [Rule] = []
        if let re = try? NSRegularExpression(pattern: "^" + pat + "$", options: [.dotMatchesLineSeparators]) {
            r.append(Rule(re: re, names: names, out: out, hint: hint, prefix: false))
        }
        // 以固定文字结尾的长句也认句首：日志里常是两句拼起来写的
        if case .text = ps.last, hint.count >= 4, let re = try? NSRegularExpression(pattern: "^" + pat, options: [.dotMatchesLineSeparators]) {
            r.append(Rule(re: re, names: names, out: out, hint: hint, prefix: true))
        }
        return r
    }
}
