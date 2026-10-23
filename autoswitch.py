#!/usr/bin/env python3
"""Codex 额度用完自动切号 + 在原对话里自动续答（launchd 常驻的守护进程）

数据来源
  - Codex 桌面端把每个对话的事件流写进 ~/.codex/sessions/**/rollout-*.jsonl。
    撞限信号只认结构化字段，不全文搜关键词（对话内容里提到 usage limit 不会误触发）：
      event_msg/token_count  的 rate_limits（rate_limit_reached_type 非空或已用 ≥100%）
      event_msg/task_complete 的 error.codex_error_info == "usage_limit_exceeded"
  - 每个账号的实时额度来自 engine.fetch_usage（Codex 自己 /status 用的接口）。
    rollout 信号只是「可能撞限」，切号前一律联网确认，迟到的旧事件不会误切。

切号
  从当前槽往后按字母顺序找第一个联网确认可用的槽；都不可用就进入等待，
  睡到最早恢复的时刻，到点联网确认后再切（当前账号先恢复就不切，直接续答）。
  用户手动切到可用账号也会结束等待。

续答
  切号会重启 ChatGPT，正在跑的轮次都会被掐断。切号前把触发撞限的对话和所有
  正在跑的主对话放进续答队列并落盘（守护进程重启也不丢）。新 App 起来、内部总线
  ~/.codex/ipc/ipc.sock 握手成功后：
    1. 该对话在切号之后已经有新轮次（用户手动继续了）→ 出队；
    2. thread-owner-discovery 看 App 是否已接管该对话，没有就发深链
       codex://threads/<id> 让 App 打开它（App 在跑时深链才会交给这个实例）；
    3. 已接管 → thread-follower-start-turn 发一句「继续」，由 App 本体执行，
       回复实时出现在原对话框里。
  总线协议：帧 = 4 字节小端长度 + JSON；先 initialize 拿 clientId；不带 targetClientId
  的请求由路由器询问各客户端 canHandle，对话的 owner 应答。我们自己也会收到
  client-discovery-request，要立刻答 canHandle=false，否则别人的请求白等 10 秒。

停滞看门狗（autoswitch.json 的 stall_nudge）
  某对话的轮次在跑、却 STALL_NOTIFY 秒没有任何新事件 → 发通知；再过 STALL_NUDGE 秒
  仍无动静 → 给这一轮 steer 一句「继续」，每轮最多一次。
"""
import os, re, sys, json, time, glob, socket, struct, uuid, signal, subprocess, datetime
import threading, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("engine", os.path.join(HERE, "engine.py"))
eng = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eng)
t = eng.t                  # 给人看的话按界面语言取（英文表见下面「英文译文」一节）

CODEX_HOME = os.path.expanduser("~/.codex")
SESSIONS   = os.path.join(CODEX_HOME, "sessions")
IPC_SOCK   = os.path.join(CODEX_HOME, "ipc", "ipc.sock")
LOG_FILE   = os.path.join(eng.P, "autoswitch.log")

POLL            = 3        # 主循环间隔（秒）
ACTIVE_WINDOW   = 900      # 文件 15 分钟内有写入，其中未结束的轮次才算「在跑」
USAGE_CUR_EVERY = 180      # 当前账号额度联网刷新间隔
USAGE_ALL_EVERY = 600      # 全部账号额度联网刷新间隔
DIRECTORY_EVERY = 1800     # 空间 / 订阅 / 成员目录同步间隔（顺带生成续费、新成员提醒）
RESET_BUFFER    = 60       # 到重置时刻后再多等一会儿，吸收服务器时间抖动
APP_READY_MAX   = 180      # 切号后等新 App 就绪的上限
DEEPLINK_EVERY  = 20       # 同一个对话两次深链之间至少隔这么久
RESUME_GIVEUP   = 900      # 续答 15 分钟还送不进去就放弃并通知
QUEUE_WAIT      = 45       # 后台续答：排进队列后这么久还没开跑，就撤掉排队、退回深链 + 总线的老办法
WAKE_EVERY      = 15       # 排队后没开跑时，隔这么久再发一次唤醒链接
DRAIN_MAX       = 3600     # 撞限后先等同账号上别的在跑的对话自己停下再切号（额度到了服务端往往还让当前这一轮做完），
                           # 只是兜底上限。切号要退出 ChatGPT，还在跑的轮次会被打断，ChatGPT 会暂停被打断对话的待发队列，
                           # 后台排队的「继续」就跑不起来，只能打开对话去发。15 分钟没动静的轮次不算在跑（见 ACTIVE_WINDOW）
STALL_NOTIFY    = 900
STALL_NUDGE     = 600
START_GAP       = 60       # 自动开始计时：两个账号之间至少隔这么久
START_RETRY     = 1800     # 自动开始计时失败的账号，过这么久再试
CONTINUE_DELAY  = 180      # 回合正常结束后等这么久还没有新消息，才自动继续（给人留时间自己接）
LOG_MAX         = 2_000_000


# ---------- 日志 / 通知 / 状态 ----------
def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX:
            with open(LOG_FILE, encoding="utf-8", errors="replace") as f:
                keep = f.read()[-LOG_MAX // 2:]
            with open(LOG_FILE, "w", encoding="utf-8") as f:
                f.write(keep)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {msg}\n")
    except OSError:
        pass


def notify(text, level="info", kind="switch"):
    """记进消息中心并弹 macOS 通知；失败不影响主流程"""
    try:
        eng.push_event(kind, text, level=level)
    except Exception as e:
        log(t("写消息中心失败：{err}", err=f"{type(e).__name__}: {e}"))


def hm(epoch):
    """时间戳 → 「10-21 18:52」，今天的只显示「18:52」"""
    if not epoch:
        return t("未知")
    d = datetime.datetime.fromtimestamp(epoch)
    return d.strftime("%H:%M") if d.date() == datetime.date.today() else d.strftime("%m-%d %H:%M")


def iso_ts(s):
    """rollout 每行顶层 timestamp（ISO 8601，UTC）→ epoch；失败返回 None"""
    if not isinstance(s, str) or not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


# ---------- rollout 读取 ----------
_meta = {}


def _read_meta(path):
    """rollout 首行 session_meta → (对话 id, 父对话 id, 工作目录)，带缓存"""
    if path not in _meta:
        tid = parent = cwd = None
        try:
            with open(path, "rb") as f:
                o = json.loads(f.readline())
            if o.get("type") == "session_meta":
                p = o.get("payload") or {}
                tid = p.get("id") or p.get("session_id")
                parent = p.get("parent_thread_id")
                cwd = p.get("cwd")
        except Exception:
            pass
        _meta[path] = (tid, parent, cwd)
    return _meta[path]


def meta_of(path):
    """→ (对话 id, 父对话 id)"""
    return _read_meta(path)[:2]


def main_thread(path):
    """rollout 所属的主对话：子代理对话沿 parent_thread_id 往上找"""
    tid, parent = meta_of(path)
    return parent or tid


def thread_files(tid):
    """属于某个对话的 rollout（一个对话可能分成多段文件），最近写入的在前"""
    files = [p for p in all_rollouts() if meta_of(p)[0] == tid and not meta_of(p)[1]]
    return sorted(files, key=lambda p: os.path.getmtime(p), reverse=True)


def last_turn_end(tid):
    """对话最后一个轮次事件的类型：task_started（在跑）/ task_complete / turn_aborted（被打断）；找不到为空"""
    files = thread_files(tid)
    ev = find_last(files[0], LIFECYCLE) if files else None
    return ev[0] if ev else ""


def last_start(tid):
    """对话最后一个轮次的开始时刻（epoch），找不到为 0"""
    files = thread_files(tid)
    ev = find_last(files[0], ("task_started",)) if files else None
    return ev[2] if ev and ev[2] else 0


def limit_failed_at(tid):
    """对话最后一个轮次因额度用完失败结束的时刻；最后一轮不是这样结束的为 0"""
    files = thread_files(tid)
    ev = find_last(files[0], LIFECYCLE) if files else None
    if ev and ev[0] == "task_complete" and error_info(ev[1]) == "usage_limit_exceeded":
        return ev[2] or 0
    return 0


def all_rollouts():
    return glob.glob(os.path.join(SESSIONS, "*", "*", "*", "rollout-*.jsonl"))


LIFECYCLE = ("task_started", "task_complete", "turn_aborted")


def parse_event(raw):
    """一行 rollout → (类型, payload, 时间戳)；不是 event_msg 返回 None"""
    try:
        o = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(o, dict) or o.get("type") != "event_msg":
        return None
    p = o.get("payload")
    if not isinstance(p, dict):
        return None
    return p.get("type"), p, iso_ts(o.get("timestamp"))


def error_info(p):
    e = p.get("error")
    return str(e.get("codex_error_info") or "") if isinstance(e, dict) else ""


def error_msg(p):
    e = p.get("error")
    return str(e.get("message") or "")[:120] if isinstance(e, dict) else ""


def find_last(path, types):
    """从文件尾往前找最后一个指定类型的 event_msg → (类型, payload, 时间戳) 或 None

    窗口从 1MB 起每次 ×4，直到找到或读完整个文件：长轮次的 task_started 可能在
    几十 MB 之前。先按字节过滤再解析 JSON，大文件也不慢。
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    needles = [f'"type":"{t}"'.encode() for t in types]
    win = 1 << 20
    while True:
        start = max(0, size - win)
        try:
            with open(path, "rb") as f:
                f.seek(start)
                chunk = f.read(size - start)
        except OSError:
            return None
        lines = chunk.split(b"\n")
        if start > 0:
            lines = lines[1:]               # 第一行是半截
        for raw in reversed(lines):
            if not any(n in raw for n in needles):
                continue
            ev = parse_event(raw)
            if ev and ev[0] in types:
                return ev
        if start == 0:
            return None
        win *= 4


class Tracker:
    """增量读取所有 rollout，维护每个文件「正在跑的轮次」，产出撞限信号"""

    def __init__(self, started_at):
        self.started_at = started_at
        self.files = {}      # path -> {"off", "turn", "last"}
        self.done = []       # (path, 时刻)：正常结束（没报错）的轮次，守护进程取走
        self.user_turns = [] # (path, 时刻)：用户自己发起的轮次（turn_trigger 非空；总线续答的是 null）

    def _add(self, path):
        size = os.path.getsize(path)
        try:
            born = os.stat(path).st_birthtime
        except (OSError, AttributeError):
            born = 0
        if born >= self.started_at - 5:
            # 守护进程启动后新建的对话：从头读，开头几秒内的撞限也不漏
            self.files[path] = {"off": 0, "turn": None, "last": born}
            return
        # 已有的文件：只看之后追加的内容；最近还在写的，在跑的轮次从文件尾反查
        f = {"off": size, "turn": None, "last": os.path.getmtime(path)}
        if time.time() - f["last"] < ACTIVE_WINDOW:
            ev = find_last(path, LIFECYCLE)
            if ev and ev[0] == "task_started":
                f["turn"] = ev[1].get("turn_id")
        self.files[path] = f

    def poll(self):
        """读新内容 → (撞限信号列表, 额度快照列表)"""
        triggers, snapshots = [], []
        for path in all_rollouts():
            try:
                if path not in self.files:
                    self._add(path)
                f = self.files[path]
                size = os.path.getsize(path)
                if size < f["off"]:
                    f["off"] = 0
                if size == f["off"]:
                    continue
                with open(path, "rb") as fh:
                    fh.seek(f["off"])
                    chunk = fh.read(size - f["off"])
            except OSError:
                continue
            end = chunk.rfind(b"\n")
            if end < 0:
                continue
            f["off"] += end + 1
            f["last"] = time.time()
            for raw in chunk[:end].split(b"\n"):
                if b'"event_msg"' not in raw:
                    continue
                ev = parse_event(raw)
                if not ev:
                    continue
                kind, p, ts = ev
                ts = ts or time.time()
                if kind == "task_started":
                    f["turn"] = p.get("turn_id")
                    # composer 等 = 用户自己发的；queue = 排队消息被跑起来（我们的后台续答也走这条），
                    # 不算用户接手，否则「结束后自动继续」的次数上限会被它清零、永远停不下来
                    trig = (p.get("turn_attribution") or {}).get("turn_trigger")
                    if trig and trig != "queue":
                        self.user_turns.append((path, ts))
                elif kind in ("task_complete", "turn_aborted"):
                    f["turn"] = None
                    if kind == "task_complete" and not p.get("error"):
                        self.done.append((path, ts))
                if kind == "token_count" and isinstance(p.get("rate_limits"), dict):
                    rl = p["rate_limits"]
                    snap = rollout_snapshot(rl, ts)
                    if snap:
                        snapshots.append(snap)
                        if snap["reached"]:
                            triggers.append({"path": path, "ts": ts, "kind": "rate",
                                             "why": t("额度已用满")})
                elif error_info(p) == "usage_limit_exceeded":
                    triggers.append({"path": path, "ts": ts, "kind": "error",
                                     "why": error_msg(p) or "usage_limit_exceeded"})
        return triggers, snapshots

    def forget_turns(self):
        """ChatGPT 被重启/退出后，进行中的轮次都已死；被杀的轮次不一定写得出结束事件"""
        for f in self.files.values():
            f["turn"] = None

    def active_threads(self):
        """当前在跑轮次所属的主对话"""
        now = time.time()
        return {main_thread(p) for p, f in self.files.items()
                if f["turn"] and now - f["last"] < ACTIVE_WINDOW and main_thread(p)}


def rollout_snapshot(rl, ts):
    """token_count.rate_limits → 额度记录（只认 5 小时 / 每周这组 codex 限额）"""
    def win(w):
        if not isinstance(w, dict) or w.get("used_percent") is None:
            return None
        return {"used": float(w["used_percent"]), "reset_at": int(w.get("resets_at") or 0),
                "window": int(w.get("window_minutes") or 0) * 60}
    if rl.get("limit_id") not in (None, "codex"):
        return None
    prim, sec = eng.split_windows(win(rl.get("primary")), win(rl.get("secondary")))
    if not prim and not sec:
        return None
    reached = bool(rl.get("rate_limit_reached_type")) or \
        any(w and w["used"] >= 100 for w in (prim, sec))
    return {"at": ts, "src": "rollout", "primary": prim, "secondary": sec, "reached": reached}


def remaining(entry, now):
    """缓存里 5 小时窗口的剩余百分比；窗口已重置算 100，没数据算 0。
    没有 5 小时限额、只有每周额度的套餐，按每周剩余算"""
    w = (entry or {}).get("primary") or (entry or {}).get("secondary")
    if not w:
        return 0
    if (w.get("reset_at") or 0) <= now:
        return 100
    return max(0, 100 - w.get("used", 0))


def next_reset(entry, now):
    """缓存里 5 小时窗口下次重置的时刻；已重置、还没开始计时、没数据的排最后（不用也不会作废）"""
    w = (entry or {}).get("primary")
    if not w or (w.get("reset_at") or 0) <= now or eng.window_untouched(entry, now):
        return float("inf")
    return w["reset_at"]


def current_settings(path):
    """对话当前的模型 / 推理强度 / 速度 → {"model", "effort", "tier"}

    取最后一条 thread_settings_applied（改设置、每轮开始都会写；tier 为 priority 即快速）；
    没有就退回最后一个 turn_context（不含速度）。只看文件尾部 4MB，找不到返回空值"""
    empty = {"model": "", "effort": "", "tier": ""}
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - (4 << 20)))
            chunk = f.read()
    except OSError:
        return empty
    for raw in reversed(chunk.split(b"\n")):
        if b'"thread_settings_applied"' not in raw and b'"type":"turn_context"' not in raw:
            continue
        try:
            o = json.loads(raw)
        except ValueError:
            continue
        p = o.get("payload") or {}
        if p.get("type") == "thread_settings_applied":
            s = p.get("thread_settings") or {}
            return {"model": s.get("model") or "", "effort": s.get("reasoning_effort") or "",
                    "tier": s.get("service_tier") or ""}
        if o.get("type") == "turn_context":
            return {"model": p.get("model") or "", "effort": p.get("effort") or "", "tier": ""}
    return empty


DEMO_MODELS = [
    {"id": "gpt-6.1-sol", "name": "GPT-6.1-Sol", "efforts": ["low", "medium", "high", "xhigh", "max"], "default": "medium",
     "fast": True, "speed": 2},
    {"id": "gpt-6-luna", "name": "GPT-6-Luna", "efforts": ["low", "medium", "high", "xhigh"], "default": "medium",
     "fast": True, "speed": 1.5},
]


# ChatGPT 设置里「模型菜单显示哪些推理强度」（enabled-reasoning-efforts），没改过就是它的默认值：不含 max
EFFORTS_DEFAULT = ["low", "medium", "high", "xhigh", "ultra", "persistent"]


def enabled_efforts():
    st = eng.read_json(os.path.join(CODEX_HOME, ".codex-global-state.json"), {})
    v = st.get("enabled-reasoning-efforts") if isinstance(st, dict) else None
    return set(v) if isinstance(v, list) and v else set(EFFORTS_DEFAULT)


def models():
    """同 _models()，推理强度只留 ChatGPT 模型菜单里显示的那些"""
    ok = enabled_efforts()
    return [dict(m, efforts=[e for e in m["efforts"] if e in ok]) for m in _models()]


def _models():
    """可选模型（Codex 自己的 model/list）：id、显示名、可选推理强度、默认强度、是否有快速档、快速档几倍速。
    起 app-server 要一两秒，结果缓存一天"""
    if eng.DEMO:
        return DEMO_MODELS
    path = os.path.join(eng.P, "models.json")
    c = eng.read_json(path, {})
    if c.get("models") and time.time() - c.get("at", 0) < 86400 and all("speed" in m for m in c["models"]):
        return c["models"]
    try:
        with AppServer() as s:
            r = s.call("model/list", {"limit": 100}, 20)
    except Exception:
        return c.get("models") or []
    out = []
    for m in ((r or {}).get("result") or {}).get("data") or []:
        if m.get("hidden"):
            continue
        fast = next((t or {} for t in m.get("serviceTiers") or [] if (t or {}).get("id") == "priority"), None)
        x = re.search(r"(\d+(?:\.\d+)?)x", (fast or {}).get("description") or "")
        out.append({"id": m.get("id") or m.get("model") or "", "name": m.get("displayName") or m.get("id") or "",
                    "efforts": [e.get("reasoningEffort") if isinstance(e, dict) else e for e in m.get("supportedReasoningEfforts") or []],
                    "default": m.get("defaultReasoningEffort") or "",
                    "fast": fast is not None, "speed": float(x.group(1)) if x else (1.5 if fast else 0)})
    if out:
        eng.write_json(path, {"at": time.time(), "models": out})
    return out or c.get("models") or []


# ---------- 会话列表（给 App 的「会话」页） ----------
SESSION_INDEX = os.path.join(CODEX_HOME, "session_index.jsonl")


def session_titles():
    """对话 id → 名称（Codex 写在 session_index.jsonl，后写的覆盖先写的）"""
    names = {}
    try:
        with open(SESSION_INDEX, encoding="utf-8", errors="replace") as f:
            for raw in f:
                try:
                    o = json.loads(raw)
                except ValueError:
                    continue
                if o.get("id") and o.get("thread_name"):
                    names[o["id"]] = o["thread_name"]
    except OSError:
        pass
    return names


def sessions(hours=48):
    """最近 hours 小时内有动静的主对话：名称、项目、状态、续答排队情况、跑在哪个账号

    账号：进行中（running / stalled）的就是当前槽；其余按切号历史取「最后一轮结束时在用的那个」。
    """
    now = time.time()
    st = eng.read_json(eng.STATE, {})
    queued = {q["thread"] for q in st.get("queue") or []}
    paused = st.get("paused") or {}
    app_up = bool(eng.running())
    titles = session_titles()
    hist = eng.switch_history()
    cur_slot = eng.current_slot() or ""
    cur_mail = (eng.info(eng.AUTH) or {}).get("email") or ""
    groups = {}                                  # 主对话 id → {"main": 文件, "last": 最近写入}
    for p in all_rollouts():
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        if now - m > hours * 3600:
            continue
        tid, parent = meta_of(p)
        main = parent or tid
        if not main:
            continue
        g = groups.setdefault(main, {"main": None, "main_m": 0, "last": 0, "subs": 0})
        g["last"] = max(g["last"], m)
        if parent:
            g["subs"] += 1
        elif m > g["main_m"]:
            g["main"], g["main_m"] = p, m
    rows = []
    for tid, g in groups.items():
        if not g["main"]:
            continue
        ev = find_last(g["main"], LIFECYCLE)
        status, err, started = "idle", "", 0
        if ev:
            kind, p, ts = ev
            if kind == "task_started":
                started = ts or 0
                if not app_up:
                    status = "interrupted"
                elif now - g["last"] < STALL_NOTIFY:
                    status = "running"
                else:
                    status = "stalled"
            elif kind == "turn_aborted":
                status = "aborted"
            elif error_info(p) == "usage_limit_exceeded":
                status, err = "limited", error_msg(p)
            elif error_info(p):
                status, err = "error", error_msg(p) or error_info(p)
            else:
                status = "done"
        pz = paused.get(tid)
        if pz and status not in ("running", "stalled"):
            ls = find_last(g["main"], ("task_started",))
            if pz >= ((ls[2] if ls else 0) or 0):
                status = "paused"               # 在会话页暂停的，之后没开过新一轮
        cwd = _read_meta(g["main"])[2] or ""
        # 最后一轮已结束的按结束时刻算：之后文件还会被写（比如 ChatGPT 打开对话时记的 thread_settings_applied），
        # 拿文件修改时间去查切号历史，会算成后来才切过去、对话根本没在上面跑过的账号
        last = ev[2] if ev and ev[0] != "task_started" and ev[2] else g["last"]
        if status in ("running", "stalled") and cur_slot:
            slot, mail = cur_slot, cur_mail
        else:
            slot, mail = eng.slot_at(hist, last)
        rows.append({"thread": tid, "title": titles.get(tid) or "",
                     "project": os.path.basename(cwd.rstrip("/")), "cwd": cwd,
                     "status": status, "error": err, "turnStartedAt": started,
                     "lastActivity": last, "subagents": g["subs"],
                     "queued": tid in queued, "slot": slot, "email": mail, **current_settings(g["main"])})
    order = {"running": 0, "stalled": 1, "limited": 2, "interrupted": 3}
    rows.sort(key=lambda r: (order.get(r["status"], 9), -r["lastActivity"]))
    return rows


# ---------- 内部总线（IPC）客户端 ----------
class Bus:
    """~/.codex/ipc/ipc.sock 的极简客户端，一次操作一条连接"""

    def __init__(self):
        self.sock = None
        self.buf = b""
        self.me = None

    def __enter__(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(3)
        self.sock.connect(IPC_SOCK)
        rid = str(uuid.uuid4())
        self._send({"type": "request", "requestId": rid, "sourceClientId": "initializing-client",
                    "version": 0, "method": "initialize",
                    "params": {"clientType": "autoswitch-daemon"}})
        r = self._wait(rid, 8)
        self.me = ((r or {}).get("result") or {}).get("clientId")
        if not self.me:
            raise ConnectionError(t("总线握手没拿到 clientId"))
        return self

    def __exit__(self, *exc):
        try:
            self.sock.close()
        except OSError:
            pass

    def _send(self, obj):
        data = json.dumps(obj).encode()
        self.sock.sendall(struct.pack("<I", len(data)) + data)

    def _wait(self, rid, seconds):
        """收帧直到拿到 rid 的响应；顺手对路由器的发现询问答「不处理」"""
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.sock.settimeout(max(0.1, min(1.0, deadline - time.time())))
            try:
                chunk = self.sock.recv(1 << 20)
            except socket.timeout:
                continue
            if not chunk:
                raise ConnectionError(t("总线连接被关闭"))
            self.buf += chunk
            while len(self.buf) >= 4:
                (n,) = struct.unpack("<I", self.buf[:4])
                if len(self.buf) < 4 + n:
                    break
                body, self.buf = self.buf[4:4 + n], self.buf[4 + n:]
                try:
                    msg = json.loads(body)
                except ValueError:
                    continue
                if msg.get("type") == "client-discovery-request":
                    self._send({"type": "client-discovery-response",
                                "requestId": msg.get("requestId"),
                                "response": {"canHandle": False}})
                elif msg.get("requestId") == rid and msg.get("type") == "response":
                    return msg
        return None

    def request(self, method, version, params, seconds):
        rid = str(uuid.uuid4())
        self._send({"type": "request", "requestId": rid, "sourceClientId": self.me,
                    "version": version, "method": method, "params": params})
        return self._wait(rid, seconds)

    def owned(self, tid):
        """App 是否已接管（打开过）这个对话。有窗口接管时一秒内就答；没有时路由器要 10 秒才回
        no-client-found，所以只等 4 秒，没答就当没接管（误判的代价只是多发一次深链）"""
        r = self.request("thread-owner-discovery", 1,
                         {"hostId": "local", "conversationId": tid}, 4)
        return bool(r and r.get("resultType") == "success")

    def start_turn(self, tid, text):
        r = self.request("thread-follower-start-turn", 2, {
            "conversationId": tid,
            "turnStart": {"request": {"threadId": tid, "input": [
                {"type": "text", "text": text, "text_elements": []}]}, "context": {}},
        }, 20)
        if r and r.get("resultType") == "success":
            return True, ""
        return False, (r or {}).get("error") or t("App 未在 20 秒内响应")

    def update_settings(self, tid, settings):
        """改对话下一轮起用的模型 / 推理强度 / 速度（App 里窗口接管了这个对话才行；协议版本 2）
        settings 用 app-server 的键：model / effort / serviceTier（None = 标准速度）"""
        r = self.request("thread-follower-update-thread-settings", 2, {
            "conversationId": tid, "threadSettings": settings, "activeTurnId": None, "condition": None}, 15)
        if r and r.get("resultType") == "success" and (r.get("result") or {}).get("applied"):
            return True, ""
        return False, (r or {}).get("error") or t("没有生效")

    def interrupt(self, tid, turn_id):
        """停下对话正在跑的这一轮，等同 ChatGPT 里点停止（mode user-stop）。
        带 expectedTurnId 是协议版本 4，不带是 3；轮次对不上（已经换了一轮）App 会拒绝"""
        params = {"conversationId": tid, "mode": "user-stop"}
        if turn_id:
            params["expectedTurnId"] = turn_id
        r = self.request("thread-follower-interrupt-turn", 4 if turn_id else 3, params, 15)
        if r and r.get("resultType") == "success":
            return True, ""
        return False, (r or {}).get("error") or t("App 未在 15 秒内响应")

    def steer(self, tid, text):
        r = self.request("thread-follower-steer-turn", 1, {
            "conversationId": tid,
            "input": [{"type": "text", "text": text, "text_elements": []}],
        }, 20)
        if r and r.get("resultType") == "success":
            return True, ""
        return False, (r or {}).get("error") or t("App 未在 20 秒内响应")


class AppServer:
    """自己起一个 codex app-server（stdio 上一行一条 JSON-RPC），只用来往对话的待发队列里放消息。

    待发队列存在 ~/.codex/queue_*.sqlite，和 ChatGPT 里的 app-server 共用：我们放进去，
    再发 codex://threads/wake/<id>，ChatGPT 就在后台把它跑起来。"""

    def __enter__(self):
        self.p = subprocess.Popen([eng.CODEX, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        r = self.call("initialize", {"clientInfo": {"name": "autoswitch-daemon", "title": None, "version": "0"},
                                     "capabilities": {"experimentalApi": True}}, 20)
        if not r or "result" not in r:
            raise ConnectionError(t("app-server 没有完成握手"))
        self.p.stdin.write(json.dumps({"method": "initialized"}) + "\n")
        self.p.stdin.flush()
        return self

    def __exit__(self, *exc):
        try:
            self.p.stdin.close()
            self.p.terminate()
            self.p.wait(5)
        except Exception:
            self.p.kill()

    def call(self, method, params, seconds=15):
        import select
        self.n += 1
        rid = self.n
        self.p.stdin.write(json.dumps({"id": rid, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        end = time.time() + seconds
        while time.time() < end:
            if not select.select([self.p.stdout], [], [], 0.5)[0]:
                continue
            line = self.p.stdout.readline()
            if not line:
                break
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("id") == rid:
                return m
        return None


def wake_thread(tid):
    """让 ChatGPT 在后台跑这个对话的排队消息：wake 链接不 show / focus 窗口，也不切换显示的对话"""
    subprocess.run(["/usr/bin/open", "-g", f"codex://threads/wake/{tid}"], capture_output=True, timeout=10)


def queue_continue(tids, text):
    """后台续答：把续答用语排进这些对话的待发队列（共用一个 app-server），再逐个唤醒
    → {对话 id: (排队消息 id, 错误说明)}"""
    res = {}
    try:
        with AppServer() as s:
            for tid in tids:
                r = s.call("thread/queue/add", {"threadId": tid, "clientUserMessageId": str(uuid.uuid4()),
                                                "input": [{"type": "text", "text": text, "text_elements": []}]})
                qid = (((r or {}).get("result") or {}).get("queuedSubmission") or {}).get("id")
                res[tid] = (qid, "") if qid else ("", ((r or {}).get("error") or {}).get("message") or t("app-server 没有响应"))
    except Exception as e:
        return {t: res.get(t) or ("", f"{type(e).__name__}: {e}") for t in tids}
    for tid, (qid, _) in res.items():
        if qid:
            wake_thread(tid)
    return res


def queue_drop(tid, qid):
    """撤掉还没跑的排队消息（退回老办法前，免得之后又多跑一次）
    → True 撤掉了；False 队列里已经没有它（ChatGPT 已经取走去跑了）；None 没问成（app-server 出错）"""
    try:
        with AppServer() as s:
            r = s.call("thread/queue/delete", {"threadId": tid, "queuedSubmissionId": qid})
    except Exception:
        return None
    res = (r or {}).get("result")
    return None if res is None else bool(res.get("deleted"))


def bus_ready():
    try:
        with Bus():
            return True
    except (OSError, ConnectionError):
        return False


# ---------- 守护进程 ----------
class Daemon:
    def __init__(self):
        self.started_at = time.time()
        self.tracker = Tracker(self.started_at)
        self.st = eng.read_json(eng.STATE, {})
        for k, v in (("queue", []), ("wait", None), ("drain", None), ("last_switch_at", 0), ("nudged", {}), ("continued", {})):
            self.st.setdefault(k, v)
        self.st["switching"] = None          # 重启后不可能还在切号中途
        self.cur = eng.current_slot()
        self.last_cur_usage = 0
        self.last_all_usage = 0
        self.last_directory = 0
        self.stall = {}                      # path -> 已通知时刻
        self.ignore_rate_until = 0
        self.stopping = False
        self.starting = False                # 自动开始计时的请求正在发
        self.last_start = 0
        self.start_fail = {}                 # slot -> 失败后到这个时刻再试
        self.finished = {}                   # 对话 id -> 正常结束时刻（等 CONTINUE_DELAY 后自动继续）

    # ----- 状态 -----
    def save(self, phase, text):
        self.st["status"] = {"phase": phase, "text": text}
        self.st["heartbeat"] = time.time()
        try:
            eng.write_json(eng.STATE, self.st)
        except OSError as e:
            log(t("保存状态失败：{err}", err=e))

    def status_text(self, cfg):
        if not cfg["enabled"] and not self.st["queue"]:
            return "off", t("自动切号已关闭")
        if self.st.get("switching"):
            return "switching", t("正在切到 {to}，等待 ChatGPT 启动", to=self.st['switching']['to'])
        if self.st.get("drain"):
            return "switching", t("额度用完，等其他对话停下后切号")
        if self.st.get("wait"):
            return "waiting", t("全部账号额度用完，{at} 自动继续", at=hm(self.st['wait']['until']))
        if self.st["queue"]:
            return "resuming", t("正在续答 {n} 个对话", n=len(self.st['queue']))
        return "idle", t("监控中")

    # ----- 额度 -----
    def refresh_usage(self, now):
        if self.cur and now - self.last_cur_usage >= USAGE_CUR_EVERY:
            self.last_cur_usage = now
            eng.fetch_usage(self.cur)
        if now - self.last_directory >= DIRECTORY_EVERY:
            self.last_directory = now
            threading.Thread(target=self.sync_directory, daemon=True).start()
        if now - self.last_all_usage >= USAGE_ALL_EVERY:
            self.last_all_usage = now
            others = [s for s in eng.slots() if s != self.cur]
            threading.Thread(target=lambda: [eng.fetch_usage(s) for s in others],
                             daemon=True).start()

    # ----- 自动开始计时 -----
    def auto_start(self, cfg, now):
        """5 小时窗口还没开始的账号，挨个发一句极短的请求让它从现在起算（设置里「自动开始计时」）

        每次只发一个、两个之间至少隔 START_GAP；候选要求额度数据新鲜，全部账号每 10 分钟刷新一次，
        所以窗口重置后最晚约 10 分钟就会被起算。切号中途不发，免得和换凭证抢令牌。
        """
        if not cfg.get("auto_start") or self.starting or self.st.get("switching"):
            return
        if now - self.last_start < START_GAP:
            return
        todo = [s for s in eng.start_candidates(now) if self.start_fail.get(s, 0) <= now]
        if not todo:
            return
        self.starting, self.last_start = True, now
        threading.Thread(target=self.start_one, args=(todo[0],), daemon=True).start()

    def start_one(self, slot):
        try:
            ok, err, _ = eng.start_window(slot)
        except Exception as e:
            ok, err = False, f"{type(e).__name__}: {e}"
        try:
            mail = (eng.info(eng.slot_path(slot)) or {}).get("email") or t("槽 {slot}", slot=slot)
            if ok:
                log(t("自动开始计时：{mail} 的 5 小时额度已开始计时", mail=mail))
            else:
                self.start_fail[slot] = time.time() + START_RETRY
                log(t("自动开始计时失败：{mail}：{err}，{n} 分钟后再试", mail=mail, err=err, n=START_RETRY // 60))
                notify(t("{mail} 自动开始计时失败：{err}", mail=mail, err=err), "warn", "quota")
        finally:
            self.last_start = time.time()
            self.starting = False

    def sync_directory(self):
        try:
            eng.sync_directory()
        except Exception as e:
            log(t("同步账号目录失败：{err}", err=f"{type(e).__name__}: {e}"))

    def usable_now(self, slot, now):
        """联网确认某槽现在可用；查询失败时按缓存判断。返回 (可用?, 恢复时刻或 None)"""
        if eng.needs_login(eng.slot_path(slot)):
            return False, None
        e = eng.fetch_usage(slot)
        t = eng.available_at(e, now)
        if t == 0:
            return True, None
        if t is None:
            # 连不上、或凭证过期（切过去时会刷新）：算可用，切过去真不行会再次撞限并被挡住
            return True, None
        return False, t

    def pick(self, now, include_current):
        """找下一个可用槽 → (槽或 None, 最早恢复时刻)

        顺序（设置里的 order）：alpha = 从当前槽往后按字母找；soon = 缓存里 5 小时窗口最早
        重置的优先（快重置了，剩下的额度不用就作废）；most = 缓存里 5 小时
        剩余最多的优先。无论哪种，候选都要联网确认后才用。
        """
        sl = eng.slots()
        if not sl:
            return None, None
        i = sl.index(self.cur) if self.cur in sl else -1
        order = sl[i + 1:] + sl[:i + 1] if i >= 0 else sl
        cfg = eng.load_config()
        how = cfg["order"]
        order = [s for s in order if s == self.cur or s not in cfg["skip"]]   # 不参与轮换的不切过去；当前就在它上面时照常留着
        if how in ("most", "soon"):
            q = eng.load_quota()
            key = (lambda s: -remaining(q.get(s), now)) if how == "most" else (lambda s: next_reset(q.get(s), now))
            order.sort(key=key)                # sort 稳定，同分保持字母序
        if include_current and self.cur in order:
            order = [self.cur] + [s for s in order if s != self.cur]
        elif self.cur in order:
            order.remove(self.cur)
        earliest = None
        for s in order:
            ok, t = self.usable_now(s, now)
            if ok:
                return s, None
            if t:
                earliest = t if earliest is None else min(earliest, t)
        return None, earliest

    # ----- 撞限 → 切号 / 等待 -----
    def on_triggers(self, triggers, now):
        """处理这一轮读到的所有撞限信号（同一轮可能有好几个对话同时撞限）"""
        floor = max(self.st["last_switch_at"], self.started_at) - 1
        triggers = [t for t in triggers if t["ts"] >= floor]   # 丢掉旧账号的迟到事件
        if not triggers or self.st.get("switching"):
            return
        if not self.cur:
            log(t("检测到撞限，但当前凭证不属于任何槽位，无法自动切"))
            return
        threads = {main_thread(t["path"]) for t in triggers} - {None}
        if self.st.get("wait") or self.st.get("drain"):
            self.enqueue(threads, now)          # 等待中 / 正等别的对话停下：记下来，切号后一起续答
            return
        errs = [t for t in triggers if t["kind"] == "error"]
        if not errs and now < self.ignore_rate_until:
            return                             # 刚联网确认过仍可用，别每轮都去查
        why = (errs or triggers)[0]["why"]
        e = eng.fetch_usage(self.cur)
        back = eng.available_at(e, now)
        full = [w["reset_at"] for w in (e.get("primary"), e.get("secondary")) if eng.window_full(w, now)]
        if back == 0 and not e.get("error") and not errs:
            log(t("槽 {slot} 出现额度用满信号，但联网确认仍可用，忽略", slot=self.cur))
            self.ignore_rate_until = now + 60
            return
        if back is None or e.get("error"):
            eng.merge_quota(self.cur, {"block_until": now + 1800,
                                       "block_reason": t("撞限，额度查询失败（{err}）", err=e.get('error'))})
        elif errs and not full:
            # 轮次因限额失败、窗口却没用满（如 team 空间 credits 用完）：先挡半小时。服务端这时常说可用，
            # 或 limit_reached 过一会儿又变回 false，不挡的话一会儿就被当成可用、切回来再撞
            eng.merge_quota(self.cur, {"block_until": now + 1800, "block_reason": why[:80]})
        log(t("槽 {slot} 额度用完（{why}）", slot=self.cur, why=why))
        last = main_thread(triggers[-1]["path"])
        self.enqueue(threads, now, last=last)
        busy = self.tracker.active_threads() - threads
        if busy:
            # 同账号上还有对话在跑：等它们自己撞限停下再切，免得退出 ChatGPT 时被打断（见 DRAIN_MAX）。
            # 记下剩余重置券数、用满窗口的重置时刻，等的时候据此认出「当前号恢复了」（见 cur_recovered）
            self.st["drain"] = {"since": now, "slot": self.cur, "resets": e.get("resets"),
                                "full_until": max(full, default=0)}
            log(t("还有 {n} 个对话在跑，等它们都自己停下再切号（最多等 {m} 分钟）", n=len(busy), m=DRAIN_MAX // 60))
            return
        self.rotate(now, t("槽 {slot} 额度用完", slot=self.cur))

    def cur_recovered(self, d, live=False):
        """撞限后（d = drain 记录）当前账号又能用了：先要有恢复的依据 —— 用了重置券（在这里用的，或剩余券数
        比撞限时少，即在 ChatGPT 里用的）、或撞限时用满的窗口已到重置时刻 —— 再看 d["since"] 之后的额度记录没用满。
        光看「没用满」不行：team 空间 credits 用完时服务端照样说 0%、可用，会在同一个号上反复续答、反复撞限。
        live = 先联网查一次再判断，否则看缓存（当前槽每 USAGE_CUR_EVERY 刷新一次）"""
        if not self.cur:
            return False
        now = time.time()
        e = (eng.fetch_usage(self.cur) if live else eng.load_quota().get(self.cur)) or {}
        if e.get("error") or e.get("at", 0) <= d["since"]:
            return False
        credit = (e.get("credit_used_at") or 0) > d["since"] or \
            (d.get("resets") is not None and (e.get("resets") or 0) < d["resets"])
        reset = 0 < (d.get("full_until") or 0) <= now
        # 撞限时挡的半小时不算：恢复的依据已经有了
        if not (credit or reset) or eng.available_at(dict(e, block_until=0), now) != 0:
            return False
        eng.merge_quota(self.cur, {"block_until": 0})
        return True

    def check_drain(self, now):
        """撞限后在等别的对话停下：都停了（做完、撞限、或 15 分钟没动静）就切号；等够 DRAIN_MAX 还在跑的
        照常切号，并加进续答队列。等的时候当前账号又能用了（比如用了重置券）就不切号，直接续答"""
        d = self.st.get("drain")
        if not d:
            return
        if self.cur != d["slot"]:
            self.st["drain"] = None              # 期间手动切了号
            return
        if self.cur_recovered(d):
            self.st["drain"] = None
            log(t("槽 {slot} 已恢复可用（比如用了重置券），不切号，直接续答", slot=self.cur))
            return
        busy = self.tracker.active_threads()
        if busy and now - d["since"] < DRAIN_MAX:
            return
        self.st["drain"] = None
        # 切号前联网再确认一次：缓存可能是几分钟前的
        if self.cur_recovered(d, live=True):
            log(t("槽 {slot} 已恢复可用（比如用了重置券），不切号，直接续答", slot=self.cur))
            return
        if busy:
            log(t("等了 {m} 分钟还有 {n} 个对话在跑，照常切号（它们会被打断，切号后打开对话续答）", m=DRAIN_MAX // 60, n=len(busy)))
            self.enqueue(busy, now)
        else:
            log(t("同账号上的对话都已停下，切号"))
        self.rotate(now, t("槽 {slot} 额度用完", slot=self.cur))

    def rotate(self, now, reason):
        # 兜底：上次切号以来因限额停下的对话都进续答队列（撞限信号偶尔漏掉、或被 enqueue 去重吞掉）
        missed = self.limited_since(self.st["last_switch_at"], now) - {q["thread"] for q in self.st["queue"]}
        if missed:
            log(t("切号前补查到 {n} 个因额度用完停下、还没排上的对话，一并续答", n=len(missed)))
            self.enqueue(missed, now)
        nxt, earliest = self.pick(now, include_current=False)
        if nxt:
            self.switch_to(nxt, now, reason)
            return
        until = (earliest or now + 600) + RESET_BUFFER
        self.st["wait"] = {"until": until, "since": now}
        log(t("{reason}，其他账号也都不可用，等到 {at} 再试", reason=reason, at=hm(until)))
        notify(t("所有账号额度都用完了，{at} 自动继续", at=hm(until)), "warn")

    def switch_to(self, slot, now, reason):
        log(t("{reason} → 切到槽 {slot}", reason=reason, slot=slot))
        self.st["wait"] = None
        quiet = eng.load_config()["quiet_switch"]
        front = eng.frontmost() if quiet else ""     # 切号前用户在用的 App，ChatGPT 起来后把焦点还给它
        ok, r = eng.switch(slot, background=quiet)
        if not ok:
            log(t("切号失败：{err}", err=r.get('err')))
            notify(t("自动切号失败：{err}", err=r.get('err')), "critical")
            eng.merge_quota(slot, {"block_until": now + 600, "block_reason": t("切号失败")})
            return
        self.cur = slot
        self.st["last_switch_at"] = time.time()
        self.st["switching"] = {"to": slot, "at": time.time()}
        if front:
            # ChatGPT 启动、建窗口的这段时间里它随时可能抢前台，单开一个线程盯着，抢了就把焦点还回去
            def guard():
                if eng.give_back(front, 45):
                    log(t("ChatGPT 启动时跳到了最前面，已把焦点还给原来的窗口"))
            threading.Thread(target=guard, daemon=True).start()
        self.last_cur_usage = 0
        self.tracker.forget_turns()          # 旧 App 里的轮次已随重启结束
        log(t("已切到槽 {slot}（{email}），等待 ChatGPT 就绪", slot=slot, email=r.get('email')))
        notify(t("已切到 {email}，稍后在原对话里继续", email=r.get('email')))

    def check_wait(self, now):
        w = self.st.get("wait")
        if not w:
            return
        e = eng.load_quota().get(self.cur) if self.cur else None
        # 用户手动切到了一个可用的号、或当前号已恢复：直接结束等待
        if self.cur and eng.available_at(e, now) == 0 and \
                (e or {}).get("at", 0) > w["since"]:
            self.st["wait"] = None
            log(t("当前槽 {slot} 已可用，结束等待", slot=self.cur))
            return
        if now < w["until"]:
            return
        nxt, earliest = self.pick(now, include_current=True)
        if nxt == self.cur:
            self.st["wait"] = None
            log(t("槽 {slot} 额度已恢复，无需切号，直接续答", slot=self.cur))
            notify(t("额度已恢复，继续工作"))
        elif nxt:
            self.switch_to(nxt, now, t("等待到点"))
        else:
            w["until"] = (earliest or now + 600) + RESET_BUFFER
            log(t("到点后仍没有可用账号，继续等到 {at}", at=hm(w['until'])))

    # ----- 续答 -----
    def enqueue(self, threads, now, last=None, manual=False, auto=False):
        """auto = 回合正常结束后的自动继续（和 manual 一样不受自动切号总开关影响）"""
        known = {q["thread"] for q in self.st["queue"]}
        # 触发撞限的那个对话放最后：深链依次打开，界面最后停在它上面
        for tid in sorted(threads - {None}, key=lambda t: t == last):
            if manual:
                self.unpause(tid)
            elif self.is_paused(tid):
                log(t("对话 {id}… 是在会话页暂停的，不自动续答", id=tid[:8]))
                continue
            if tid not in known:
                self.st["queue"].append({"thread": tid, "since": now, "added": now, "base": last_start(tid),
                                         "linked": 0, "manual": manual, "auto": auto})
                log(t("对话 {id}… 加入续答队列", id=tid[:8]))

    def is_paused(self, tid):
        """在会话页点过「暂停」、之后还没开过新一轮"""
        at = (self.st.get("paused") or {}).get(tid)
        return bool(at) and at >= last_start(tid)

    def unpause(self, tid):
        (self.st.get("paused") or {}).pop(tid, None)

    def app_ready(self, now):
        """切号后等新 App 起来；返回 True 表示可以开始续答"""
        sw = self.st.get("switching")
        if not eng.running():
            if sw and now - sw["at"] > APP_READY_MAX:
                log(t("切号后 ChatGPT 迟迟没有启动，放弃等待"))
                self.st["switching"] = None
            return False
        if not bus_ready():
            if sw and now - sw["at"] > APP_READY_MAX:
                log(t("切号后 ChatGPT 的内部总线迟迟不可用，放弃等待"))
                self.st["switching"] = None
            return False
        if sw:
            if now - sw.get("bus_at", now) < 5:
                sw.setdefault("bus_at", now)   # 总线刚通，窗口可能还没建好，缓几秒
                return False
            log(t("ChatGPT 已就绪（切号后 {sec:.0f} 秒）", sec=now - sw['at']))
            self.st["switching"] = None
        return True

    def resumed_by_someone(self, item):
        """加入队列之后该对话已经有新轮次（排队的跑起来了、用户手动继续了、或别处已续答）

        base = 加入队列时它最后一个轮次的开始时刻，比它新的就算；旧队列项没有 base，按加入时刻
        +1 秒判断（会话页点「继续」后一秒内就开跑，那种情况必须用 base，不然认不出来）"""
        files = thread_files(item["thread"])
        if not files:
            return None
        ev = find_last(files[0], ("task_started",))
        t = ev[2] if ev and ev[2] else 0
        return t > item["base"] if "base" in item else t > item["since"] + 1

    def use_queue(self, cfg, item):
        """这条续答走「排进 ChatGPT 的待发队列 + 唤醒」吗：后台切号、或会话页点的「继续」（bg）。
        手动切号时勾选的续答照旧打开对话给人看；排队失败过的改走深链"""
        return (cfg["quiet_switch"] or item.get("bg")) and not item.get("manual") and not item.get("no_queue")

    def process_queue(self, cfg, now):
        # 等别的对话停下（drain）时也不续：账号已经用完，这时发「继续」只会再撞一次限，还把等待拖长
        if not self.st["queue"] or self.st.get("wait") or self.st.get("drain"):
            return
        if not self.app_ready(now):
            return
        q = self.st["queue"]
        # 1. 已经跑起来的（排队的开跑了、或用户自己继续了）、该放弃的，先清掉
        for item in list(q):
            tid = item["thread"]
            # 放弃计时从真正开始续答算起：等额度重置可能要等好几个小时
            item.setdefault("started", now)
            done = self.resumed_by_someone(item)
            failed = limit_failed_at(tid) if done else 0
            if done is None:
                log(t("续答跳过：找不到对话 {id}… 的记录文件", id=tid[:8]))
                q.remove(item)
            elif failed:
                # 新的一轮也因额度用完失败了，不算续上（比如排的「继续」在切号前的旧账号上跑了）
                if failed < self.st["last_switch_at"]:
                    # 失败在切号之前：以这一轮为新起点，在现在的账号上再排一次
                    item["base"] = last_start(tid)
                    for k in ("qid", "queued_at", "woke"):
                        item.pop(k, None)
                    log(t("对话 {id}… 续答的那一轮在切号前的账号上因额度用完失败了，在当前账号上再续", id=tid[:8]))
                else:
                    # 就在当前账号上失败的：撞限流程会接手（切号后再续），这里不再原地重发
                    q.remove(item)
                    log(t("续答没成功：对话 {id}… 的这一轮也因额度用完失败了", id=tid[:8]))
                    if item.get("bg") or item.get("manual"):
                        notify(t("续答没成功：当前账号额度用完了"), "warn", "session")
            elif done:
                q.remove(item)
                # 新轮次不一定是我们排的那条跑起来的（比如在 ChatGPT 里点了继续）：撤掉，免得残留在队列里
                if item.get("qid") and queue_drop(tid, item["qid"]):
                    log(t("对话 {id}… 已在别处继续，撤掉了排队的「{prompt}」", id=tid[:8], prompt=cfg['prompt']))
                elif item.get("qid"):
                    log(t("续答成功：对话 {id}… 已在后台跑起排队的「{prompt}」", id=tid[:8], prompt=cfg['prompt']))
                    if not q and not item.get("auto"):
                        notify(t("已在原对话里继续") if item.get("bg") else t("已切号并在原对话里继续"), kind="session")
                else:
                    log(t("对话 {id}… 已有新轮次（可能已手动继续），不再续答", id=tid[:8]))
            elif now - item["started"] > RESUME_GIVEUP:
                q.remove(item)
                if item.get("qid"):
                    queue_drop(tid, item["qid"])
                log(t("续答放弃：{m} 分钟内没能在对话 {id}… 里继续", m=RESUME_GIVEUP // 60, id=tid[:8]))
                notify(t("没能自动继续对话，请在原对话里手动发一句「继续」") if item.get("auto") or item.get("bg")
                       else t("切号后没能自动续答，请在原对话里手动发一句「继续」"), "warn", "session")
        # 2. 后台排队：能排的一次全排进去、一起唤醒，ChatGPT 在后台跑，不弹窗口、不跳到对话。
        #    排队后迟迟没开跑（App 版本不支持、唤醒丢了……）就撤掉排队，退回下面深链 + 总线的老办法
        for i in q:
            if self.use_queue(cfg, i) and not i.get("qid") and last_turn_end(i["thread"]) == "turn_aborted":
                # 上一轮被打断的对话，ChatGPT 会暂停它的待发队列（「由于你中断了当前响应，队列已暂停」），
                # 排进去也不会跑，还会留在那里：直接打开对话发
                i["no_queue"] = True
                log(t("对话 {id}… 上一轮被打断，ChatGPT 会暂停它的待发队列，改为打开对话发送", id=i['thread'][:8]))
        todo = [i for i in q if self.use_queue(cfg, i)]
        fresh = [i for i in todo if not i.get("qid") and now >= i.get("retry_at", 0)]
        if fresh:
            got = queue_continue([i["thread"] for i in fresh], cfg["prompt"])
            for i in fresh:
                qid, err = got.get(i["thread"]) or ("", t("app-server 没有响应"))
                if qid:
                    i.update(qid=qid, queued_at=now, woke=now)
                    log(t("已把「{prompt}」排进对话 {id}… 的待发队列，等 ChatGPT 在后台跑起来", prompt=cfg['prompt'], id=i['thread'][:8]))
                else:
                    i["no_queue"] = True
                    log(t("对话 {id}… 后台排队续答不可用（{err}），改用深链", id=i['thread'][:8], err=err))
        for i in todo:
            if not i.get("qid") or i in fresh:
                continue
            if now - i["queued_at"] < QUEUE_WAIT:
                if now - i["woke"] >= WAKE_EVERY:
                    i["woke"] = now
                    wake_thread(i["thread"])
                continue
            dropped = queue_drop(i["thread"], i["qid"])
            if dropped:
                i["no_queue"] = True
                i.pop("qid", None)
                log(t("对话 {id}… 排队 {sec} 秒还没跑起来，已撤掉，改用深链", id=i['thread'][:8], sec=QUEUE_WAIT))
            elif dropped is False:
                # 队列里已经没有它：ChatGPT 取走跑了（记录文件里没认出来新轮次，比如刚好在同一秒开跑）
                q.remove(i)
                log(t("续答成功：对话 {id}… 排队的「{prompt}」已被 ChatGPT 取走运行", id=i['thread'][:8], prompt=cfg['prompt']))
            else:
                i["queued_at"] = now             # 没问成，再等一轮
        # 3. 深链 + 总线：一次只处理一个
        item = next((i for i in q if not i.get("qid") and not self.use_queue(cfg, i)), None)
        if not item or now < item.get("retry_at", 0):
            return
        tid = item["thread"]
        try:
            with Bus() as bus:
                if not bus.owned(tid):
                    if now - item["linked"] >= DEEPLINK_EVERY:
                        item["linked"] = now
                        # 后台切号 / 会话页的「继续」：深链也不抢前台（手动切号时勾选的续答照旧跳过去给人看）
                        quiet = (cfg["quiet_switch"] or item.get("bg")) and not item.get("manual")
                        front = eng.frontmost() if quiet else ""
                        subprocess.run(["/usr/bin/open"] + (["-g"] if quiet else []) + [f"codex://threads/{tid}"],
                                       capture_output=True, timeout=10)
                        log(t("App 还没打开对话 {id}…，已在后台发深链", id=tid[:8]) if quiet else t("App 还没打开对话 {id}…，已发深链", id=tid[:8]))
                        if quiet and eng.give_back(front, 4):   # ChatGPT 打开对话时会自己 focus 窗口
                            log(t("ChatGPT 打开对话时跳到了最前面，已把焦点还给原来的窗口"))
                    return
                ok, err = bus.start_turn(tid, cfg["prompt"])
        except (OSError, ConnectionError) as e:
            log(t("续答时总线异常：{err}", err=f"{type(e).__name__}: {e}"))
            return
        if ok:
            q.remove(item)
            log(t("续答成功：已在对话 {id}… 里发送「{prompt}」", id=tid[:8], prompt=cfg['prompt']))
            if not q and not item.get("auto"):
                notify(t("已在原对话里继续") if item.get("bg") else t("已切号并在原对话里继续"), kind="session")
        else:
            item["retry_at"] = now + 10
            log(t("续答未成功（{err}），10 秒后重试", err=err))

    # ----- 回合结束后自动继续 -----
    def check_done(self, cfg, now):
        """主对话的轮次正常结束（模型自己停下，不是额度用完）CONTINUE_DELAY 后还没有新消息，
        就发续答用语。同一个对话连续自动继续 continue_max 次后停下等人；用户自己发一条消息就重新计数。
        """
        done, user = self.tracker.done, self.tracker.user_turns
        self.tracker.done, self.tracker.user_turns = [], []
        cont = self.st["continued"]
        if cfg["auto_continue"]:
            for path, ts in done:
                tid, parent = meta_of(path)
                if tid and not parent:          # 子代理结束是正常流程，主对话会自己接着跑
                    self.finished[tid] = ts
        for path, ts in user:
            tid = main_thread(path)
            if self.finished.get(tid, 0) <= ts:
                self.finished.pop(tid, None)
            if cont.pop(tid, None):
                log(t("对话 {id}… 有你发的新消息，自动继续重新计数", id=tid[:8]))
        if not cfg["auto_continue"]:
            self.finished.clear()
            return
        for tid, ts in list(self.finished.items()):
            if now - ts < CONTINUE_DELAY or self.st.get("switching") or self.st.get("wait"):
                continue
            self.finished.pop(tid)
            if not eng.running():
                continue                        # ChatGPT 被关掉了：多半是人不想让它接着跑
            c = cont.setdefault(tid, {"n": 0})
            c["at"] = now
            if c["n"] >= cfg["continue_max"]:
                if not c.get("told"):
                    c["told"] = True
                    log(t("对话 {id}… 已连续自动继续 {n} 次，到上限，停下等你", id=tid[:8], n=c['n']))
                    notify(t("有对话已连续自动继续 {n} 次，到上限停下了，请看一下", n=c['n']), "warn", "session")
                continue
            c["n"] += 1
            log(t("对话 {id}… 回合正常结束 {m} 分钟没有新消息，自动继续（第 {n}/{max} 次）",
                  id=tid[:8], m=CONTINUE_DELAY // 60, n=c['n'], max=cfg['continue_max']))
            self.enqueue({tid}, ts, auto=True)
        # 计数只留三天
        self.st["continued"] = {k: v for k, v in cont.items() if now - v.get("at", 0) < 3 * 86400}

    # ----- 停滞看门狗 -----
    def check_stall(self, cfg, now):
        if not cfg["stall_nudge"] or self.st.get("switching") or self.st["queue"]:
            return
        if not eng.running():
            self.tracker.forget_turns()
            return
        for path, f in self.tracker.files.items():
            if not f["turn"]:
                self.stall.pop(path, None)
                continue
            idle = now - f["last"]
            if idle < STALL_NOTIFY:
                self.stall.pop(path, None)
                continue
            tid = main_thread(path)
            if not tid or idle > ACTIVE_WINDOW + STALL_NUDGE + 600:
                continue                     # 太久没动的是 App 被杀留下的僵尸轮次
            if path not in self.stall:
                self.stall[path] = now
                log(t("对话 {id}… 已 {m:.0f} 分钟没有新进展", id=tid[:8], m=idle / 60))
                notify(t("有对话已 {m:.0f} 分钟没有新进展", m=idle / 60), "warn", "session")
            key = f"{tid}:{f['turn']}"
            if now - self.stall[path] >= STALL_NUDGE and key not in self.st["nudged"]:
                self.st["nudged"][key] = now
                try:
                    with Bus() as bus:
                        ok, err = bus.steer(tid, cfg["prompt"])
                except (OSError, ConnectionError) as e:
                    ok, err = False, str(e)
                log(t("停滞干预（对话 {id}…）：{res}", id=tid[:8],
                      res=t("已送「{prompt}」", prompt=cfg['prompt']) if ok else t("未成功 {err}", err=err)))
        # 记录只留一天
        self.st["nudged"] = {k: v for k, v in self.st["nudged"].items() if now - v < 86400}

    # ----- 启动时补漏 -----
    def limited_since(self, t0, now):
        """最近 30 分钟内、t0 之后以限额报错结束（最后一个轮次事件就是它）的主对话"""
        out = set()
        for path in all_rollouts():
            if now - os.path.getmtime(path) > 1800:
                continue
            ev = find_last(path, LIFECYCLE)
            if ev and ev[0] == "task_complete" and error_info(ev[1]) == "usage_limit_exceeded" \
                    and ev[2] and now - ev[2] < 1800 and ev[2] > t0:
                out.add(main_thread(path))
        out.discard(None)
        return out

    def catch_up(self, now):
        """守护进程不在的时候撞了限：最近 30 分钟内以限额报错结束的对话也要处理"""
        missed = self.limited_since(self.st["last_switch_at"], now)
        if not missed or not self.cur:
            return
        ok, _ = self.usable_now(self.cur, now)
        if ok:
            log(t("启动补查：{n} 个对话最近因额度用完而停下，当前槽 {slot} 可用，直接续答", n=len(missed), slot=self.cur))
        else:
            log(t("启动补查：{n} 个对话最近因额度用完而停下，当前槽 {slot} 不可用，切号", n=len(missed), slot=self.cur))
        self.enqueue(missed, now - 1)
        if not ok:
            self.rotate(now, t("槽 {slot} 额度用完（启动补查）", slot=self.cur))

    # ----- 主循环 -----
    def run(self):
        signal.signal(signal.SIGTERM, lambda *a: setattr(self, "stopping", True))
        signal.signal(signal.SIGINT, lambda *a: setattr(self, "stopping", True))
        cfg = eng.load_config()
        log(t("守护进程启动：自动切号开，当前槽 {slot}，续答队列 {n} 个", slot=self.cur, n=len(self.st['queue']))
            if cfg['enabled'] else
            t("守护进程启动：自动切号关，当前槽 {slot}，续答队列 {n} 个", slot=self.cur, n=len(self.st['queue'])))
        self.tracker.poll()                  # 建立基线（启动前的历史不触发）
        if cfg["enabled"]:
            self.catch_up(time.time())
        while not self.stopping:
            try:
                self.tick()
            except Exception as e:
                log(t("主循环异常（继续运行）：{err}", err=f"{type(e).__name__}: {e}"))
            time.sleep(POLL)
        self.save("off", t("守护进程已停止"))
        log(t("守护进程退出"))

    def take_requests(self, now):
        """engine.py --resume / --continue 留下的续答请求：字符串是 --resume（打开对话给人看），
        {"thread", "bg"} 是会话页的「继续」（后台跑）"""
        try:
            with eng.file_lock("request"):
                req = eng.read_json(eng.REQUEST, None)
                if req is not None:
                    os.remove(eng.REQUEST)
        except OSError:
            return
        if not req:
            return
        manual = [t for t in req if isinstance(t, str)]
        bg = [t["thread"] for t in req if isinstance(t, dict) and t.get("thread") and t.get("bg")]
        sets = [t for t in req if isinstance(t, dict) and t.get("thread") and t.get("settings")]
        pauses = [t["thread"] for t in req if isinstance(t, dict) and t.get("thread") and t.get("pause")]
        if pauses:
            self.queue_pauses(pauses, now)
            bg = [t for t in bg if t not in pauses]
        if sets:
            self.queue_settings(sets, now)
        if manual:
            log(t("收到手动续答请求：{ids}", ids=', '.join(x[:8] for x in manual)))
            self.enqueue(set(manual), now, manual=True)
        if bg:
            log(t("会话页点了「继续」：{ids}", ids=', '.join(x[:8] for x in bg)))
            self.continue_now(bg, now)

    def queue_pauses(self, tids, now):
        """会话页的「暂停」：移出续答队列、取消待发的自动继续；正在跑的记进待办，process_pauses 经总线停"""
        tids = list(dict.fromkeys(tids))
        q = self.st["queue"]
        gone = [i for i in q if i["thread"] in tids]
        for i in gone:
            q.remove(i)
            if i.get("qid"):
                queue_drop(i["thread"], i["qid"])
        marks = self.st.setdefault("paused", {})
        for tid in tids:
            self.finished.pop(tid, None)
            marks[tid] = now                    # 会话页显示「已暂停」，自动续答也跳过它，直到开了新一轮
        self.st["paused"] = {k: v for k, v in marks.items() if now - v < 3 * 86400}
        pq = self.st.setdefault("pause_q", [])
        run = [t for t in tids if last_turn_end(t) == "task_started" and not any(i["thread"] == t for i in pq)]
        pq.extend({"thread": t, "added": now, "linked": 0} for t in run)
        log(t("会话页点了「暂停」：{ids}", ids=', '.join(x[:8] for x in tids))
            + (t("（{n} 个移出续答队列）", n=len(gone)) if gone else "") + (t("，{n} 个正在跑的去停下", n=len(run)) if run else ""))

    def process_pauses(self, now):
        """一次停一个：App 里有窗口接管这个对话就直接停；没有就后台深链打开再停。2 分钟停不下就放弃"""
        q = self.st.get("pause_q") or []
        if not q or not eng.running() or now < q[0].get("retry_at", 0):
            return
        item = q[0]
        tid = item["thread"]
        ev = None
        files = thread_files(tid)
        if files:
            ev = find_last(files[0], LIFECYCLE)
        if not ev or ev[0] != "task_started":
            q.pop(0)
            log(t("对话 {id}… 这一轮已经停了，不用再暂停", id=tid[:8]))
            return
        if now - item["added"] > 120:
            q.pop(0)
            log(t("暂停对话 {id}…：2 分钟没能停下，放弃", id=tid[:8]))
            notify(t("有对话没能暂停，请在 ChatGPT 里手动点停止"), "warn", "session")
            return
        try:
            with Bus() as bus:
                if not bus.owned(tid):
                    if now - item["linked"] >= DEEPLINK_EVERY:
                        item["linked"] = now
                        front = eng.frontmost()
                        subprocess.run(["/usr/bin/open", "-g", f"codex://threads/{tid}"], capture_output=True, timeout=10)
                        eng.give_back(front, 4)
                    return
                ok, err = bus.interrupt(tid, (ev[1] or {}).get("turn_id") or "")
        except (OSError, ConnectionError) as e:
            ok, err = False, f"{type(e).__name__}: {e}"
        if ok:
            q.pop(0)
            log(t("已暂停对话 {id}…（停下了正在跑的这一轮）", id=tid[:8]))
        else:
            item["retry_at"] = now + 5
            log(t("暂停对话 {id}… 未成功（{err}），5 秒后重试", id=tid[:8], err=err))

    def queue_settings(self, reqs, now):
        """会话页改模型 / 推理强度 / 速度：记进待办，process_settings 逐个经总线改；同一对话的合并成一条"""
        q = self.st.setdefault("settings_q", [])
        for r in reqs:
            item = next((i for i in q if i["thread"] == r["thread"]), None)
            if item:
                item["settings"].update(r["settings"])
            else:
                q.append({"thread": r["thread"], "settings": dict(r["settings"]), "added": now, "linked": 0})
        log(t("会话页改模型 / 速度：{n} 个对话 → {settings}", n=len(reqs),
              settings=t("、").join(f"{k}={v}" for k, v in reqs[0]["settings"].items())))

    def process_settings(self, now):
        """一次改一个：App 里已有窗口接管这个对话就直接改；没有就在后台用深链打开它（窗口会闪一下，焦点还回去）。
        改的是下一轮起的设置，正在跑的这一轮不变"""
        q = self.st.get("settings_q") or []
        if not q or self.st.get("switching") or not eng.running() or now < q[0].get("retry_at", 0):
            return
        item = q[0]
        tid = item["thread"]
        if now - item["added"] > 600:
            q.pop(0)
            log(t("改对话 {id}… 的模型 / 速度：10 分钟没能生效，放弃", id=tid[:8]))
            notify(t("有对话的模型 / 速度没改成功，请在 ChatGPT 里手动改"), "warn", "session")
            return
        s = item["settings"]
        params = {}
        if s.get("model"):
            params["model"] = s["model"]
        if s.get("effort"):
            params["effort"] = s["effort"]
        if s.get("tier"):
            params["serviceTier"] = None if s["tier"] == "default" else s["tier"]
        try:
            with Bus() as bus:
                if not bus.owned(tid):
                    if now - item["linked"] >= DEEPLINK_EVERY:
                        item["linked"] = now
                        front = eng.frontmost()
                        subprocess.run(["/usr/bin/open", "-g", f"codex://threads/{tid}"], capture_output=True, timeout=10)
                        eng.give_back(front, 4)
                    return
                ok, err = bus.update_settings(tid, params)
        except (OSError, ConnectionError) as e:
            ok, err = False, f"{type(e).__name__}: {e}"
        if ok:
            q.pop(0)
            log(t("已改对话 {id}… 的设置（下一轮起生效）：{settings}", id=tid[:8],
                  settings=t("、").join(f"{k}={v}" for k, v in s.items())))
        else:
            item["retry_at"] = now + 10
            log(t("改对话 {id}… 的设置未成功（{err}），10 秒后重试", id=tid[:8], err=err))

    def continue_now(self, tids, now):
        """会话页的「继续」/「全部继续」：后台排队续答，插到队列最前面马上处理。
        已在队列里的（比如切号后还没轮到的）改成后台方式并提前；排队失败过的再试一次"""
        q = self.st["queue"]
        front = []
        for tid in dict.fromkeys(tids):
            self.unpause(tid)
            item = next((i for i in q if i["thread"] == tid), None)
            if item:
                q.remove(item)
                if not item.get("qid"):
                    item.pop("no_queue", None)
                item.update(bg=True, manual=False, retry_at=0)
            else:
                item = {"thread": tid, "since": now, "added": now, "base": last_start(tid), "linked": 0,
                        "manual": False, "auto": False, "bg": True}
                log(t("对话 {id}… 加入续答队列", id=tid[:8]))
            front.append(item)
        self.st["queue"] = front + q
        # 等别的对话停下（drain）、全部用完在等（wait）时队列不动，点了「继续」不能没反应
        if self.st.get("wait"):
            self.st["wait"]["until"] = now       # 马上重新挑号：当前号恢复了就直接续答，别的号能用就切过去
        elif self.st.get("drain"):
            if self.cur_recovered(self.st["drain"], live=True):
                self.st["drain"] = None
                log(t("槽 {slot} 已恢复可用（比如用了重置券），不切号，直接续答", slot=self.cur))
            else:
                msg = t("当前账号额度还没恢复，这些对话已排到最前面，等同账号上的对话停下、切号后马上继续")
                log(msg)
                notify(msg, "warn", "session")

    def tick(self):
        cfg = eng.load_config()
        now = time.time()
        self.take_requests(now)
        cur = eng.current_slot()
        if cur != self.cur:
            if not self.st.get("switching"):
                log(t("检测到手动切号：{old} → {new}", old=self.cur, new=cur))
                self.st["last_switch_at"] = now
                self.tracker.forget_turns()
            self.cur = cur
            self.last_cur_usage = 0
        triggers, snaps = self.tracker.poll()
        # 只记最新一条；切号前旧账号的额度快照不能记到新账号头上
        if snaps and self.cur and snaps[-1]["at"] > self.st["last_switch_at"]:
            eng.merge_quota(self.cur, snaps[-1])
        self.refresh_usage(now)
        self.auto_start(cfg, now)            # 不受自动切号开关影响
        if cfg["enabled"]:
            self.on_triggers(triggers, now)
            self.check_drain(now)
            self.check_wait(now)
            self.check_stall(cfg, now)
        elif self.st.get("wait") or self.st.get("drain") or \
                any(not (q.get("manual") or q.get("auto") or q.get("bg")) for q in self.st["queue"]):
            log(t("自动切号已关闭，清空等待和自动续答队列"))
            self.st["wait"] = self.st["drain"] = None
            self.st["queue"] = [q for q in self.st["queue"] if q.get("manual") or q.get("auto") or q.get("bg")]
        self.check_done(cfg, now)            # 回合结束后自动继续：有自己的开关
        # 手动续答请求（会话页的「继续」/ 手动切号时勾选）、自动继续不受总开关影响
        self.process_pauses(now)
        self.process_settings(now)
        self.process_queue(cfg, now)
        self.save(*self.status_text(cfg))


# ---------- 英文译文 ----------
# 本文件里 t("…") 用到的句子；engine.py 的 EN 表里有同一句的，译文要和那边一样
eng.EN.update({
    "写消息中心失败：{err}": "Failed to write to Messages: {err}",
    "未知": "unknown",                       # 和 engine.py 一致
    "额度已用满": "Usage limit reached",
    "总线握手没拿到 clientId": "Bus handshake returned no clientId",
    "总线连接被关闭": "Bus connection closed",
    "App 未在 20 秒内响应": "App didn't respond within 20 s",
    "没有生效": "Didn't take effect",
    "App 未在 15 秒内响应": "App didn't respond within 15 s",
    "app-server 没有完成握手": "app-server didn't complete the handshake",
    "app-server 没有响应": "app-server didn't respond",
    "保存状态失败：{err}": "Failed to save state: {err}",
    # 状态（App 顶部 / 概览）
    "自动切号已关闭": "Auto-switch is off",
    "正在切到 {to}，等待 ChatGPT 启动": "Switching to {to}, waiting for ChatGPT to start",
    "额度用完，等其他对话停下后切号": "Usage used up, switching once other conversations stop",
    "全部账号额度用完，{at} 自动继续": "All accounts used up, resuming automatically at {at}",
    "正在续答 {n} 个对话": "Resuming conversations: {n}",
    "监控中": "Monitoring",
    "守护进程已停止": "Background service stopped",
    # 自动开始计时 / 目录同步
    "槽 {slot}": "Slot {slot}",
    "自动开始计时：{mail} 的 5 小时额度已开始计时": "Auto-start timer: started the 5-hour timer for {mail}",
    "自动开始计时失败：{mail}：{err}，{n} 分钟后再试": "Auto-start timer failed: {mail}: {err}, retrying in {n} min",
    "{mail} 自动开始计时失败：{err}": "Auto-start timer failed for {mail}: {err}",
    "同步账号目录失败：{err}": "Failed to sync the account directory: {err}",
    # 撞限 → 切号 / 等待
    "检测到撞限，但当前凭证不属于任何槽位，无法自动切":
        "Usage limit hit, but the current credentials don't belong to any slot; can't change accounts automatically",
    "槽 {slot} 出现额度用满信号，但联网确认仍可用，忽略":
        "Slot {slot} signaled the limit was reached, but an online check says it's still usable; ignoring",
    "撞限，额度查询失败（{err}）": "Usage limit hit; usage check failed ({err})",
    "槽 {slot} 额度用完（{why}）": "Slot {slot} used up ({why})",
    "还有 {n} 个对话在跑，等它们都自己停下再切号（最多等 {m} 分钟）":
        "Conversations still running: {n}; letting them stop on their own before switching (up to {m} min)",
    "槽 {slot} 额度用完": "Slot {slot} used up",
    "等了 {m} 分钟还有 {n} 个对话在跑，照常切号（它们会被打断，切号后打开对话续答）":
        "After {m} min, conversations still running: {n}; switching anyway "
        "(they'll be interrupted and resumed after the switch)",
    "同账号上的对话都已停下，切号": "All conversations on this account have stopped; switching",
    "切号前补查到 {n} 个因额度用完停下、还没排上的对话，一并续答":
        "Before switching, found conversations stopped by the limit but not queued: {n}; resuming them too",
    "{reason}，其他账号也都不可用，等到 {at} 再试": "{reason}; no other account is available, trying again at {at}",
    "所有账号额度都用完了，{at} 自动继续": "All accounts are used up; resuming automatically at {at}",
    "{reason} → 切到槽 {slot}": "{reason} → switching to slot {slot}",
    "切号失败：{err}": "Switch failed: {err}",
    "自动切号失败：{err}": "Auto-switch failed: {err}",
    "切号失败": "Switch failed",
    "ChatGPT 启动时跳到了最前面，已把焦点还给原来的窗口":
        "ChatGPT jumped to the front on launch; focus returned to the previous window",
    "已切到槽 {slot}（{email}），等待 ChatGPT 就绪": "Switched to slot {slot} ({email}), waiting for ChatGPT to be ready",
    "已切到 {email}，稍后在原对话里继续": "Switched to {email}; continuing in the original conversations shortly",
    "当前槽 {slot} 已可用，结束等待": "Current slot {slot} is available; done waiting",
    "槽 {slot} 已恢复可用（比如用了重置券），不切号，直接续答":
        "Slot {slot} is usable again (a reset credit was used, for example); not switching, resuming now",
    "当前账号额度还没恢复，这些对话已排到最前面，等同账号上的对话停下、切号后马上继续":
        "The current account is still used up; these conversations are first in line and will continue "
        "as soon as the other conversations on this account stop and the app switches accounts",
    "对话 {id}… 续答的那一轮在切号前的账号上因额度用完失败了，在当前账号上再续":
        "Conversation {id}…: the resumed turn failed on the previous account (usage limit); resuming again on the current account",
    "续答没成功：对话 {id}… 的这一轮也因额度用完失败了":
        "Resume failed: conversation {id}…'s new turn also hit the usage limit",
    "续答没成功：当前账号额度用完了": "Couldn't resume: the current account is used up",
    "槽 {slot} 额度已恢复，无需切号，直接续答": "Slot {slot} has recovered; no switch needed, resuming directly",
    "额度已恢复，继续工作": "Usage recovered, back to work",
    "等待到点": "Done waiting",
    "到点后仍没有可用账号，继续等到 {at}": "Still no account available; next try at {at}",
    # 续答
    "对话 {id}… 是在会话页暂停的，不自动续答": "Conversation {id}… was paused in Sessions; not auto-resuming",
    "对话 {id}… 加入续答队列": "Conversation {id}… added to the resume queue",
    "切号后 ChatGPT 迟迟没有启动，放弃等待": "ChatGPT didn't start after the switch; gave up waiting",
    "切号后 ChatGPT 的内部总线迟迟不可用，放弃等待":
        "ChatGPT's internal bus stayed unavailable after the switch; gave up waiting",
    "ChatGPT 已就绪（切号后 {sec:.0f} 秒）": "ChatGPT is ready ({sec:.0f} s after the switch)",
    "续答跳过：找不到对话 {id}… 的记录文件": "Resume skipped: no session file found for conversation {id}…",
    "对话 {id}… 已在别处继续，撤掉了排队的「{prompt}」":
        "Conversation {id}… continued elsewhere; withdrew the queued “{prompt}”",
    "续答成功：对话 {id}… 已在后台跑起排队的「{prompt}」":
        "Resume succeeded: conversation {id}… started the queued “{prompt}” in the background",
    "已切号并在原对话里继续": "Switched accounts and continued in the original conversation",
    "已在原对话里继续": "Continued in the original conversation",
    "对话 {id}… 已有新轮次（可能已手动继续），不再续答":
        "Conversation {id}… already has a new turn (maybe continued manually); not resuming",
    "续答放弃：{m} 分钟内没能在对话 {id}… 里继续": "Resume gave up: couldn't continue conversation {id}… within {m} min",
    "没能自动继续对话，请在原对话里手动发一句「继续」":
        "Couldn't continue the conversation automatically; send “continue” in it manually",
    "切号后没能自动续答，请在原对话里手动发一句「继续」":
        "Couldn't auto-resume after the switch; send “continue” in the original conversation manually",
    "对话 {id}… 上一轮被打断，ChatGPT 会暂停它的待发队列，改为打开对话发送":
        "Conversation {id}…: last turn was interrupted, so ChatGPT pauses its queue; opening the conversation to send instead",
    "已把「{prompt}」排进对话 {id}… 的待发队列，等 ChatGPT 在后台跑起来":
        "Queued “{prompt}” in conversation {id}…; ChatGPT will run it in the background",
    "对话 {id}… 后台排队续答不可用（{err}），改用深链":
        "Conversation {id}…: background queue unavailable ({err}); using a deep link",
    "对话 {id}… 排队 {sec} 秒还没跑起来，已撤掉，改用深链":
        "Conversation {id}…: queued {sec} s without starting; withdrawn, using a deep link",
    "续答成功：对话 {id}… 排队的「{prompt}」已被 ChatGPT 取走运行":
        "Resume succeeded: ChatGPT picked up the queued “{prompt}” in conversation {id}…",
    "App 还没打开对话 {id}…，已发深链": "App hasn't opened conversation {id}… yet; sent a deep link",
    "App 还没打开对话 {id}…，已在后台发深链": "App hasn't opened conversation {id}… yet; sent a deep link in the background",
    "ChatGPT 打开对话时跳到了最前面，已把焦点还给原来的窗口":
        "ChatGPT jumped to the front when opening the conversation; focus returned to the previous window",
    "续答时总线异常：{err}": "Bus problem while resuming: {err}",
    "续答成功：已在对话 {id}… 里发送「{prompt}」": "Resume succeeded: sent “{prompt}” in conversation {id}…",
    "续答未成功（{err}），10 秒后重试": "Resume didn't go through ({err}); retrying in 10 s",
    # 回合结束后自动继续 / 停滞看门狗
    "对话 {id}… 有你发的新消息，自动继续重新计数": "Conversation {id}… has a new message from you; auto-continue count reset",
    "对话 {id}… 已连续自动继续 {n} 次，到上限，停下等你":
        "Conversation {id}… auto-continued {n} times in a row; limit reached, stopped for you",
    "有对话已连续自动继续 {n} 次，到上限停下了，请看一下":
        "A conversation auto-continued {n} times in a row and hit the limit; please take a look",
    "对话 {id}… 回合正常结束 {m} 分钟没有新消息，自动继续（第 {n}/{max} 次）":
        "Conversation {id}…: turn ended normally, no new messages for {m} min; auto-continuing ({n}/{max})",
    "对话 {id}… 已 {m:.0f} 分钟没有新进展": "Conversation {id}…: no new progress for {m:.0f} min",
    "有对话已 {m:.0f} 分钟没有新进展": "A conversation has had no new progress for {m:.0f} min",
    "停滞干预（对话 {id}…）：{res}": "Stalled turn nudge (conversation {id}…): {res}",
    "已送「{prompt}」": "sent “{prompt}”",
    "未成功 {err}": "didn't go through: {err}",
    # 启动 / 主循环
    "启动补查：{n} 个对话最近因额度用完而停下，当前槽 {slot} 可用，直接续答":
        "Startup check: conversations recently stopped by the limit: {n}; current slot {slot} is available, resuming directly",
    "启动补查：{n} 个对话最近因额度用完而停下，当前槽 {slot} 不可用，切号":
        "Startup check: conversations recently stopped by the limit: {n}; current slot {slot} is unavailable, switching",
    "槽 {slot} 额度用完（启动补查）": "Slot {slot} used up (startup check)",
    "守护进程启动：自动切号开，当前槽 {slot}，续答队列 {n} 个":
        "Background service started: Auto-switch on, current slot {slot}, resume queue {n}",
    "守护进程启动：自动切号关，当前槽 {slot}，续答队列 {n} 个":
        "Background service started: Auto-switch off, current slot {slot}, resume queue {n}",
    "主循环异常（继续运行）：{err}": "Main loop exception (still running): {err}",
    "守护进程退出": "Background service exited",
    # 会话页：继续 / 暂停 / 改模型
    "收到手动续答请求：{ids}": "Manual resume request received: {ids}",
    "会话页点了「继续」：{ids}": "Sessions: Continue clicked: {ids}",
    "会话页点了「暂停」：{ids}": "Sessions: Pause clicked: {ids}",
    "（{n} 个移出续答队列）": " ({n} removed from the resume queue)",
    "，{n} 个正在跑的去停下": ", stopping {n} running",
    "对话 {id}… 这一轮已经停了，不用再暂停": "Conversation {id}…: turn already stopped, no need to pause",
    "暂停对话 {id}…：2 分钟没能停下，放弃": "Pause conversation {id}…: couldn't stop it within 2 min, gave up",
    "有对话没能暂停，请在 ChatGPT 里手动点停止": "A conversation couldn't be paused; click Stop in ChatGPT manually",
    "已暂停对话 {id}…（停下了正在跑的这一轮）": "Paused conversation {id}… (stopped the running turn)",
    "暂停对话 {id}… 未成功（{err}），5 秒后重试": "Pausing conversation {id}… didn't go through ({err}); retrying in 5 s",
    "会话页改模型 / 速度：{n} 个对话 → {settings}": "Sessions: change model / speed for conversations: {n} → {settings}",
    "、": ", ",
    "改对话 {id}… 的模型 / 速度：10 分钟没能生效，放弃":
        "Change model / speed for conversation {id}…: didn't take effect within 10 min, gave up",
    "有对话的模型 / 速度没改成功，请在 ChatGPT 里手动改":
        "Couldn't change a conversation's model / speed; change it in ChatGPT manually",
    "已改对话 {id}… 的设置（下一轮起生效）：{settings}":
        "Changed settings for conversation {id}… (from the next turn): {settings}",
    "改对话 {id}… 的设置未成功（{err}），10 秒后重试":
        "Changing settings for conversation {id}… didn't go through ({err}); retrying in 10 s",
    "检测到手动切号：{old} → {new}": "Manual switch detected: {old} → {new}",
    "自动切号已关闭，清空等待和自动续答队列": "Auto-switch turned off; clearing the waiting state and auto-resume queue",
})

if __name__ == "__main__":
    if "--models-json" in sys.argv:
        print(json.dumps({"models": models()}, ensure_ascii=False))
    elif "--sessions-json" in sys.argv:
        print(json.dumps({"sessions": sessions()}, ensure_ascii=False))
    else:
        Daemon().run()
