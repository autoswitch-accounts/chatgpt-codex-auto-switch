#!/usr/bin/env python3
"""查英文界面有没有漏翻、漏包（改了界面文字后跑一下）：

  scripts/i18n_check.py            Swift + Python 都查
  scripts/i18n_check.py swift      只查 Swift（要编译一遍，约半分钟）
  scripts/i18n_check.py python     只查 engine.py / autoswitch.py

Swift：用编译器自己的 -emit-localized-strings 列出所有会查表的键（Text("…")、L("…") 等，插值变成 %@ / %lld），
  对照 App/en.lproj/Localizable.strings 和 .stringsdict：
    缺译文     编译器列出来了、英文表里没有
    没包       源码里的中文字面量没有被查表（传给了 String 参数、拼接了等），要改成 L("…")
    格式不符   译文里的 %@ / %lld 和键对不上
  不该翻的中文（比如和 Python 输出比对的）在那一行末尾写 // i18n-ignore。
Python：t("…") 的键要在 EN 表里，花括号参数要对得上；没过 t() 的中文字符串（文档字符串除外）列出来，
  不该翻的在那一行末尾写 # i18n-ignore。
有问题时返回码 1。
"""
import ast, glob, json, os, plistlib, re, string, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CJK = re.compile(r"[一-鿿]")
SPEC = re.compile(r"%(?:(\d+)\$)?(?:[-+ 0#]*\d*(?:\.\d+)?)(lld|llu|ld|lu|lf|@|d|f|%)")


def specs(s):
    """格式符：[(位置或 None, 类型)]，不含 %%"""
    return [(m.group(1), m.group(2)) for m in SPEC.finditer(s) if m.group(2) != "%"]


def same_specs(key, val):
    k, v = specs(key), specs(val)
    if any(p for p, _ in v):                       # 译文用了 %1$@ 这种带位置的
        return sorted(int(p) if p else i + 1 for i, (p, _) in enumerate(v)) == list(range(1, len(k) + 1)) and \
            all(k[(int(p) if p else i + 1) - 1][1] == t for i, (p, t) in enumerate(v))
    return [t for _, t in k] == [t for _, t in v]


# ---------- Swift ----------
def swift_literals(path):
    """源码里带中文的字符串字面量：[(行号, 原文)]。跳过注释，处理插值和 #"raw"#"""
    src = open(path, encoding="utf-8").read()
    out, i, n, line = [], 0, len(src), 1
    stack = []          # 插值里的括号深度
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1; i += 1; continue
        if src.startswith("//", i):
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i); line += src.count("\n", i, j); i = n if j < 0 else j + 2; continue
        if stack and c == "(":
            stack[-1] += 1; i += 1; continue
        if stack and c == ")":
            stack[-1] -= 1
            if stack[-1] == 0:
                stack.pop(); i += 1
                i, line = _string_rest(src, i, line, out, start_line=None, buf=None, stack=stack)
                continue
            i += 1; continue
        if src.startswith('#"', i):
            j = src.find('"#', i + 2)
            if CJK.search(src[i:j]): out.append((line, src[i + 2:j]))
            line += src.count("\n", i, j); i = j + 2; continue
        if c == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                if CJK.search(src[i:j]): out.append((line, src[i + 3:j]))
                line += src.count("\n", i, j); i = j + 3; continue
            i, line = _string_rest(src, i + 1, line, out, start_line=line, buf=[], stack=stack)
            continue
        i += 1
    return out


_open = {}          # 插值打断的字面量：栈深度 → (起始行, 已收集的文字)


def _string_rest(src, i, line, out, start_line, buf, stack):
    """从字符串内部继续读到结尾或下一个 \\(；返回新位置"""
    depth = len(stack)
    if start_line is None:                       # 从插值里回来，接上之前那段
        start_line, buf = _open.pop(depth + 1)
    while i < len(src):
        c = src[i]
        if c == "\\" and i + 1 < len(src) and src[i + 1] == "(":
            _open[depth + 1] = (start_line, buf + ["%@"])
            stack.append(1)
            return i + 2, line
        if c == "\\":
            buf.append(src[i:i + 2]); i += 2; continue
        if c == '"':
            s = "".join(buf)
            if CJK.search(s): out.append((start_line, s))
            return i + 1, line
        if c == "\n": line += 1
        buf.append(c); i += 1
    return i, line


def check_swift(problems):
    files = sorted(glob.glob(os.path.join(ROOT, "App", "*.swift")))
    with tempfile.TemporaryDirectory() as tmp:
        r = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.0", "-Onone", "-wmo",
                            "-c", *files, "-o", os.path.join(tmp, "x.o"),
                            "-emit-localized-strings", "-emit-localized-strings-path", tmp],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[-4000:])
            problems.append("Swift 编译失败"); return
        keys = {}            # 键 → [(文件, 行)]
        at = {}              # (文件, 行) → 这一行查表的带中文的键数
        for f in glob.glob(os.path.join(tmp, "*.stringsdata")):
            d = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", f], capture_output=True, text=True).stdout)
            src = os.path.basename(d["source"])
            for e in d["tables"].get("Localizable", []):
                ln = e["location"]["startingLine"]
                keys.setdefault(e["key"], []).append((src, ln))
                if CJK.search(e["key"]): at[(src, ln)] = at.get((src, ln), 0) + 1

    en_dir = os.path.join(ROOT, "App", "en.lproj")
    strings = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", os.path.join(en_dir, "Localizable.strings")],
                                        capture_output=True, text=True).stdout or "{}")
    with open(os.path.join(en_dir, "Localizable.stringsdict"), "rb") as f:
        plurals = plistlib.load(f)
    both = set(strings) & set(plurals)
    for k in sorted(both):
        problems.append(f"重复：「{k}」同时在 .strings 和 .stringsdict 里")

    missing = [k for k in keys if CJK.search(k) and k not in strings and k not in plurals]
    for k in sorted(missing, key=lambda k: keys[k][0]):
        f, ln = keys[k][0]
        problems.append(f"缺译文 {f}:{ln}  「{k}」")
    for k, v in strings.items():
        if not same_specs(k, v):
            problems.append(f"格式不符  「{k}」→「{v}」")
        if CJK.search(v):
            problems.append(f"译文里还有中文  「{k}」→「{v}」")
    for k, d in plurals.items():
        for var, rule in d.items():
            if isinstance(rule, dict):
                for form, v in rule.items():
                    if form in ("one", "other", "zero", "two", "few", "many") and len(specs(v)) > len(specs(k)):
                        problems.append(f"格式不符（复数 {form}）  「{k}」→「{v}」")
    # L("账号#列", zh: "账号") 的键是 StaticString，编译器不一定抽得出来，直接从源码里找
    for path in files:
        for ln, line in enumerate(open(path, encoding="utf-8"), 1):
            for k in re.findall(r'L\("([^"]+)", zh:', line):
                keys.setdefault(k, []).append((os.path.basename(path), ln))
                if k not in strings:
                    problems.append(f"缺译文 {os.path.basename(path)}:{ln}  「{k}」")
    unused = sorted(k for k in list(strings) + list(plurals) if k not in keys)
    for k in unused:
        print(f"  （没用到的译文）「{k}」")

    for path in files:
        name = os.path.basename(path)
        lines = open(path, encoding="utf-8").read().split("\n")
        per = {}
        for ln, s in swift_literals(path):
            if "i18n-ignore" in lines[ln - 1]: continue
            per.setdefault(ln, []).append(s)
        for ln, lits in sorted(per.items()):
            # L("账号#列", zh: "账号") 里的 zh: 是默认值，不单独算
            if len(lits) - lines[ln - 1].count('zh: "') > at.get((name, ln), 0):
                problems.append(f"没包 {name}:{ln}  " + " | ".join(f"「{s}」" for s in lits))
    print(f"Swift：{len(keys)} 个键，英文表 {len(strings)} 条 + 复数 {len(plurals)} 条")


# ---------- Python ----------
def _en_tables(tree):
    """engine.py 的 EN = {...}、autoswitch.py 的 eng.EN.update({...})"""
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "EN" for t in node.targets) \
                and isinstance(node.value, ast.Dict):
            yield node.value
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "update" \
                and (isinstance(node.func.value, ast.Attribute) and node.func.value.attr == "EN"
                     or isinstance(node.func.value, ast.Name) and node.func.value.id == "EN") and node.args \
                and isinstance(node.args[0], ast.Dict):
            yield node.args[0]


def _fields(s):
    try:
        return sorted({f for _, f, _, _ in string.Formatter().parse(s) if f is not None})
    except ValueError as e:
        return [f"格式错误：{e}"]


def check_python(problems):
    trees = {n: ast.parse(open(os.path.join(ROOT, n), encoding="utf-8").read()) for n in ("engine.py", "autoswitch.py")}
    en, skip = {}, set()
    for name, tree in trees.items():
        for d in _en_tables(tree):
            for k, v in zip(d.keys, d.values):
                kk, vv = ast.literal_eval(k), ast.literal_eval(v)
                if kk in en and en[kk] != vv:
                    problems.append(f"EN 表里「{kk}」有两种译法")
                en[kk] = vv
            skip.update(id(x) for x in ast.walk(d))
        # EN_OLD：旧版本写下的句子，只给 App 换语言显示旧日志用；不算「没包」「没用到」，格式照查
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and any(isinstance(x, ast.Name) and x.id == "EN_OLD" for x in node.targets) \
                    and isinstance(node.value, ast.Dict):
                for k, v in zip(node.value.keys, node.value.values):
                    kk, vv = ast.literal_eval(k), ast.literal_eval(v)
                    if _fields(kk) != _fields(vv):
                        problems.append(f"格式不符（EN_OLD）  「{kk}」→「{vv}」")
                    if CJK.search(vv):
                        problems.append(f"译文里还有中文（EN_OLD）  「{kk}」→「{vv}」")
                skip.update(id(x) for x in ast.walk(node.value))
    used = set()
    for name, tree in trees.items():
        lines = open(os.path.join(ROOT, name), encoding="utf-8").read().split("\n")
        for node in ast.walk(tree):          # 文档字符串不算
            if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body \
                    and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant):
                skip.add(id(node.body[0].value))
            if isinstance(node, ast.Call) and node.args and (
                    (isinstance(node.func, ast.Name) and node.func.id == "t") or
                    (isinstance(node.func, ast.Attribute) and node.func.attr == "t")):
                a = node.args[0]
                if not isinstance(a, ast.Constant) or not isinstance(a.value, str):
                    if not isinstance(a, ast.Name):      # t(变量)：动态的话，键得在表里，这里查不了
                        problems.append(f"{name}:{node.lineno}  t() 的第一个参数要是普通字符串（不要 f-string / 拼接）")
                    continue
                skip.add(id(a)); used.add(a.value)
                kw = sorted(k.arg for k in node.keywords if k.arg)
                if _fields(a.value) != kw and kw:
                    problems.append(f"{name}:{node.lineno}  t() 的参数 {kw} 和原文里的 {_fields(a.value)} 对不上")
                if CJK.search(a.value) and a.value not in en:
                    problems.append(f"缺译文 {name}:{node.lineno}  「{a.value}」")
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in skip \
                    and CJK.search(node.value) and "i18n-ignore" not in lines[node.lineno - 1]:
                problems.append(f"没包 {name}:{node.lineno}  「{node.value[:60]}」")
    for k, v in en.items():
        if _fields(k) != _fields(v):
            problems.append(f"格式不符  「{k}」→「{v}」")
        if CJK.search(v):
            problems.append(f"译文里还有中文  「{k}」→「{v}」")
    for k in sorted(set(en) - used):
        print(f"  （没用到的译文）「{k}」")
    print(f"Python：EN 表 {len(en)} 条，用到 {len(used)} 个键")


if __name__ == "__main__":
    which = sys.argv[1:] or ["swift", "python"]
    problems = []
    if "swift" in which: check_swift(problems)
    if "python" in which: check_python(problems)
    for p in problems:
        print(p)
    print(f"共 {len(problems)} 个问题" if problems else "没问题")
    sys.exit(1 if problems else 0)
