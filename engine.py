#!/usr/bin/env python3
"""ChatGPT / Codex 账号引擎：给「ChatGPT 账号」app 和自动切号守护进程共用

槽位身份键是 tokens.account_id（workspace 级别），不是邮箱——同一个邮箱下
多个 team workspace 会有不同的 account_id，按邮箱区分会互相覆盖。

命令行（每条命令输出一行 JSON；失败时 ok=false 且返回码 1）：
  --list-json                槽位 + 额度缓存 + 自动切号状态（不联网）
  --slot X [--force]         切到槽位 X
  --refresh-usage [X ...]    联网刷新额度，不带槽位就刷新全部
  --set-auto on|off          自动切号开关
  --set-config 键 JSON值      改设置（enabled / prompt / stall_nudge / order / auto_start / auto_continue / continue_max / quiet_switch / skip / lang）
  --resume 对话id ...        请守护进程在这些对话里发一句「继续」（打开对话）
  --continue 对话id ...      同上，但在后台跑：排进 ChatGPT 的待发队列再唤醒，不切到 ChatGPT
  --pause 对话id ...         停下这些对话正在跑的这一轮（守护进程经总线停），并移出续答队列
  --set-thread JSON          改对话的模型 / 推理强度 / 速度：{"threads": [...], "settings": {"model", "effort", "tier"}}
  --directory-json [--refresh]  空间、订阅（续费 / 到期 / 席位）、成员、重置券（全部走接口）
  --hide-team / --unhide-team 空间id  团队页里移除 / 恢复一个空间（只改本机显示）
  --notices-json             消息中心
  --phrases-json             中英对照表（App 把旧消息、旧日志换成当前语言用）
  --notice-read [id ...]     标为已读（不带 id 就是全部）
  --ensure-daemon            安装 / 更新并启动守护进程（launchd）
  --rename X 名字 / --delete X
  --reset-credit X [券id]    用一张额度重置券（不给券 id 就用最早过期的那张；不可逆）
  --start-window X           发一次极小的模型请求，让 X 的 5 小时窗口开始计时
  --start-candidates         现在该自动起算 5 小时窗口的槽位（自动开始计时用，不联网）
  --meta-set wechat 邮箱 微信名 / --meta-set pay 空间id|邮箱 YYYY-MM-DD   成员台账（值为空 = 删除）
  --mark-paid 空间id|邮箱 [--undo]   标记本期已交费（下次交费顺延一个月）/ 撤销上一次标记
  添加账号流程：--next-slot / --auto-begin X / --current-json / --capture / --relaunch X
"""
import os, sys, json, base64, shutil, subprocess, time, datetime, fcntl, contextlib
import re, uuid, bisect, calendar, select, threading, importlib.util
import urllib.request, urllib.error

# ---------- 路径常量 ----------
P        = os.path.expanduser("~/Library/Application Support/codex-profiles")
NAMES    = os.path.join(P, "names.json")
BACKUP   = os.path.join(P, "backups")
LOG      = os.path.join(P, "manager.log")
LASTUSED = os.path.join(P, "lastused.json")
QUOTA    = os.path.join(P, "quota.json")
CONFIG   = os.path.join(P, "autoswitch.json")
STATE    = os.path.join(P, "daemon_state.json")
REQUEST  = os.path.join(P, "resume_request.json")
DIRECTORY = os.path.join(P, "directory.json")
HIDDEN_TEAMS = os.path.join(P, "hidden_teams.json")   # 团队页里手动移除的（已停用的）空间 id，只是不显示
NOTICES  = os.path.join(P, "notices.json")
META     = os.path.join(P, "meta.json")              # 成员台账：微信名、手动交费日
HISTORY  = os.path.join(P, "switch_history.json")    # 切号历史，用来推断对话跑在哪个账号
AUTH     = os.path.expanduser("~/.codex/auth.json")
APP_BUNDLE = "/Applications/ChatGPT.app"
CHATGPT_ID = "com.openai.codex"          # 桌面版改名叫 ChatGPT 了，bundle id 还是 codex
APP      = APP_BUNDLE + "/Contents/MacOS/ChatGPT"
# ChatGPT 26.x 把 codex 挪进了 codex-cli/bin；旧路径留作兜底
CODEX    = next((p for p in (APP_BUNDLE + "/Contents/Resources/codex-cli/bin/codex",
                             APP_BUNDLE + "/Contents/Resources/codex") if os.path.exists(p)),
                APP_BUNDLE + "/Contents/Resources/codex-cli/bin/codex")
SLOTPOOL = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

# 演示模式（scripts/demo.sh）：HOME 指向一份假数据，不联网、不碰 ChatGPT 和后台服务、不弹通知
DEMO = os.environ.get("CGA_DEMO") == "1"

DAEMON_LABEL = "com.local.chatgpt.autoswitch"
DAEMON_PLIST = os.path.expanduser(f"~/Library/LaunchAgents/{DAEMON_LABEL}.plist")
HERE = os.path.dirname(os.path.abspath(__file__))


# ---------- 基础工具 ----------
def log(msg):
    """把操作追加进日志，方便事后排查"""
    os.makedirs(P, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S}  {msg}\n")


def out(obj, ok=True):
    """输出一行 JSON 给调用方；失败时返回码 1"""
    print(json.dumps(obj, ensure_ascii=False))
    if not ok:
        sys.exit(1)


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, data):
    """原子写：先写临时文件再改名，避免读方读到半截"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# ---------- 界面语言 ----------
# 日志、通知、状态、报错这些给人看的话：中文原文当键，英文译文在 EN 表里（autoswitch.py 往里补它自己的）。
# 用 t("已切到槽 {slot}", slot=x)：带参数时按 str.format 填，所以原文里的花括号要写成 {{ }}。
# 语言是 autoswitch.json 的 lang（"zh" / "en"），App 每次启动按自己的界面语言写进去；已经写下的日志和消息不改
EN = {
    # 凭证刷新
    "读取失败": "read failed",
    "没有 refresh_token，需重新登录": "no refresh_token, needs sign-in",
    "仍有效（剩 {left:.0f} 分钟），跳过": "still valid ({left:.0f} min left), skipped",
    "网络错误 {name}": "Network error {name}",
    "响应缺 id_token": "response missing id_token",
    "已刷新": "refreshed",
    "刷新失败（{last}），需要重新登录": "refresh failed ({last}), needs sign-in",
    # 切号
    "槽位 {slot} 不存在或凭证损坏，建议删掉重新添加": "Slot {slot} is missing or its credentials are corrupted; delete it and add it again",
    "ChatGPT 没能退出，请手动 Cmd+Q 后重试": "ChatGPT didn't quit. Press Cmd+Q and try again",
    "槽 {slot} 凭证刷新：{msg}": "Slot {slot} credentials refresh: {msg}",
    "切换 {a} → {b} (槽 {slot} / {acct})": "Switched {a} → {b} (slot {slot} / {acct})",
    "无": "none",
    "切号历史：从 manager.log 回填 {n} 条": "Switch history: backfilled {n} entries from manager.log",
    "切号历史写入失败 {name}: {e}": "Failed to write switch history {name}: {e}",
    # 额度
    "凭证过期，切到这个账号一次即可刷新": "Credentials expired. Switch to this account once to refresh them",
    "演示模式不联网": "Demo mode is offline",
    "查询失败 HTTP {code}": "Query failed HTTP {code}",
    # 重置券
    "{mail} 用券后刷新券列表失败 {err}，等下次同步": "{mail}: failed to reload reset credits after use ({err}), will retry on next sync",
    "槽位 {slot} 不存在或凭证损坏": "Slot {slot} is missing or its credentials are corrupted",
    "读取重置券失败 {e}": "Failed to read reset credits {e}",
    "这个账号没有可用的重置券": "This account has no reset credits available",
    "槽 {slot} 使用重置券失败 HTTP {code}": "Slot {slot}: failed to use reset credit, HTTP {code}",
    "使用失败 HTTP {code}": "Failed to use it, HTTP {code}",
    "槽 {slot} 使用重置券失败 {name}": "Slot {slot}: failed to use reset credit, {name}",
    "槽 {slot} ({email}) 使用重置券 {credit}：{code}，重置了 {n} 个窗口":
        "Slot {slot} ({email}) used reset credit {credit}: {code}, windows reset: {n}",
    "无返回码": "no code",
    "没有重置（服务端返回 {code}）": "Not reset (server returned {code})",
    "空": "empty",
    "{email} 用了一张额度重置券": "{email} used a reset credit",
    "{email} 的这张重置券之前已用过": "{email}: this reset credit was already used",
    "槽 {slot} · 5 小时额度已用 {used:g}%": "Slot {slot} · 5-hour limit {used:g}% used",
    "槽 {slot}": "Slot {slot}",
    # 开始计时
    "流提前结束，没有 response.completed": "Stream ended early without response.completed",
    "没有可用的模型": "No usable model",
    "槽 {slot} ({email}) 起算 5 小时窗口：已发出请求（{model}）": "Slot {slot} ({email}) start the 5-hour timer: request sent ({model})",
    "槽 {slot} ({email}) 起算 5 小时窗口：失败 {err}": "Slot {slot} ({email}) start the 5-hour timer: failed {err}",
    # WebKit / 账号目录
    "WebKit 取数据没起来：{err}": "WebKit fetcher didn't start: {err}",
    "没有响应": "no response",
    "WebKit 无响应": "WebKit not responding",
    "WebKit 返回的不是 JSON": "WebKit returned non-JSON",
    "被 Cloudflare 拦截（HTTP 403）": "Blocked by Cloudflare (HTTP 403)",
    "每期减 {amount:g} {cur}": "{amount:g} {cur} off each period",
    "每期减 {amount:g} {cur}，至 {date}": "{amount:g} {cur} off each period, until {date}",
    "{mail}：空间列表 {err}": "{mail}: workspace list {err}",
    "{mail}：订阅信息暂时拿不到，沿用上次": "{mail}: subscription info unavailable, using last sync",
    "席位{e}，沿用上次": "Seats {e}, using last sync",
    "成员列表{e}，沿用 {at} 的数据": "Member list {e}, using data from {at}",
    "成员列表{e}，沿用上次的数据": "Member list {e}, using last sync",
    "成员列表{e}，暂时拿不到": "Member list {e}, unavailable for now",
    "同步账号目录失败（{err}），保留上次的数据": "Account directory sync failed ({err}), keeping the last data",
    "没有账号": "no accounts",
    "同步账号目录：{people} 个邮箱、{ws} 个空间，新消息 {new} 条":
        "Synced account directory: emails {people}, workspaces {ws}, new messages {new}",
    "，{errors} 个邮箱 / {partial} 个空间部分沿用上次数据": "; partly from last sync: emails {errors} / workspaces {partial}",
    "（直连被 Cloudflare 拦，{n} 个请求改由 App 内置 WebKit 取到）":
        " (Cloudflare blocked direct requests; {n} fetched via the App's built-in WebKit)",
    # 成员台账
    "交费日的键应为「空间id|邮箱」": "Due date key must be “workspaceId|email”",
    "日期格式应为 YYYY-MM-DD": "Date must be YYYY-MM-DD",
    "未知字段 {kind}": "Unknown field {kind}",
    "缺少邮箱": "Missing email",
    "成员台账 {kind} {key} → {value}": "Member ledger {kind} {key} → {value}",
    "（删除）": "(deleted)",
    "键应为「空间id|邮箱」": "Key must be “workspaceId|email”",
    "目录里没有这个成员，先同步一次": "This member isn't in the directory. Sync first",
    "算不出交费日": "Can't work out the due date",
    "已经是第一期了": "Already at the first period",
    "成员台账 {key} 撤销已交 → 已交到 {paid}": "Member ledger {key} undo paid → paid through {paid}",
    "成员台账 {key} {due} 这期已交": "Member ledger {key} {due} marked paid",
    # 消息中心
    "个人空间 · {email}": "Personal workspace · {email}",
    "{name} 将于 {day} 到期": "{name} expires {day}",
    "已关闭自动续费，到期后这个空间的账号将无法使用": "Auto-renew is off. Accounts in this workspace stop working once it expires",
    "{name} 将于 {day} 自动续费": "{name} renews {day}",
    " · 席位 {used}/{total}": " · Seats {used}/{total}",
    "{name} 扣费失败": "{name} payment failed",
    "订阅处于欠费状态，请尽快更新付款方式": "Subscription is past due. Update the payment method soon",
    "新成员加入 {name}": "New member joined {name}",
    "{email}（{name}） · {day} 加入": "{email} ({name}) · joined {day}",
    "{email} · {day} 加入": "{email} · joined {day}",
    "成员离开 {name}": "Member left {name}",
    "{email} · {day} 停用": "{email} · deactivated {day}",
    "{name} 发出了新邀请": "{name} sent a new invite",
    "{email} 尚未接受": "{email} hasn't accepted yet",
    "槽 {slot}（{email}）有一张额度重置券 {day} 过期": "Slot {slot} ({email}) has a reset credit expiring {day}",
    "读取 autoswitch.py 的译文失败：{err}": "Failed to read translations from autoswitch.py: {err}",
    "{title}，过期作废": "{title}, void once expired",
    "免费额度重置": "Free usage reset",
    "未知": "unknown",
    "{who} {due} 的费用已逾期 {days} 天": "{who}: payment due {due} is overdue ({days} d)",
    "{who} {due} 该交费了": "{who}: payment due {due}",
    "{name} · 所有者 {owner} · {joined} 加入": "{name} · Owner {owner} · joined {joined}",
    "（交费日手动设置）": " (due date set manually)",
    "还有 {n} 条新消息": "{n} more new messages",
    "打开「ChatGPT 账号」的消息中心查看": "Open ChatGPT Accounts to see them in Messages",
    "ChatGPT 账号": "ChatGPT Accounts",
    # 设置 / 后台服务
    "不支持的设置：{key}={value!r}": "Unsupported setting: {key}={value!r}",
    "续答用语不能为空": "Resume prompt can't be empty",
    "切号顺序只能是 alpha、most 或 soon": "Switch order must be alpha, most or soon",
    "自动继续次数上限要在 1 到 50 之间": "Auto-continue limit must be between 1 and 50",
    "lang 只能是 zh 或 en": "lang must be zh or en",
    "skip 要是槽位名列表": "skip must be a list of slot names",
    "设置 {key} = {value}": "Set {key} = {value}",
    "launchctl 返回 {code}": "launchctl returned {code}",
    "守护进程已（重新）安装": "Background service (re)installed",
    # 命令行
    "没有要暂停的对话": "No conversations to pause",
    "参数格式不对": "Invalid arguments",
    "没有要改的对话或设置": "No conversations or settings to change",
    "添加：已退出并登出，用槽 {slot} 的 profile 开窗等待登录":
        "Add: quit and signed out, opened a window with slot {slot}'s profile, waiting for sign-in",
    "槽位已满": "All slots are full",
    "添加完成（槽 {slot}），ChatGPT 已在运行": "Added (slot {slot}), ChatGPT already running",
    "添加完成，后台拉起 ChatGPT（槽 {slot}）": "Added, launching ChatGPT in the background (slot {slot})",
    "没读到凭证，可能还没登录成功": "No credentials found. Sign-in may not have finished",
    "{email} 的这个 workspace 已在槽位 {dup}": "This workspace of {email} is already in slot {dup}",
    "添加 {email} / {acct} → 槽 {slot}": "Added {email} / {acct} → slot {slot}",
    "重命名槽 {slot} → {name}": "Renamed slot {slot} → {name}",
    "不能删除当前正在使用的账号": "Can't delete the account currently in use",
    "删除槽 {slot} ({email})": "Deleted slot {slot} ({email})",
    "未知命令：{cmd}": "Unknown command: {cmd}",
    "（空）": "(empty)",
}


# 旧版本写下的句子（现在已不这么写）：只给 --phrases-json 用，让以前的日志、消息换语言后也能看懂
EN_OLD = {
    "{email} 有一张额度重置券 {day} 过期": "{email} has a reset credit expiring {day}",
    "，至 {date}": ", until {date}",
    "槽 {slot} 凭证刷新：已刷新，新 id_token 有效 {n} 分钟": "Slot {slot} token refresh: refreshed, new id_token valid for {n} min",
    "槽 {slot} 凭证刷新：刷新失败（HTTP {code}），可能需要重新登录": "Slot {slot} token refresh failed (HTTP {code}); may need to sign in again",
    "已用深链唤醒 App 到线程 {id}": "Woke the app to thread {id} via deep link",
    "续答第 {n} 次未成功（{err}），等 App 就绪后重试": "Resume attempt {n} didn't go through ({err}); retrying once the app is ready",
    "还有 {n} 个对话在跑，等它们停下再切号（最多 {s} 秒）": "{n} conversations still running; waiting for them to stop before switching (up to {s} s)",
    "冷却期内撞限（{why}），已暂存，冷却结束后处理": "Limit hit during cooldown ({why}); held until the cooldown ends",
    "冷却结束，处理暂存的撞限（{why}）": "Cooldown over; handling the held limit hit ({why})",
    "收到健康额度事件，暂存的撞限作废（迟到报错）": "Got a healthy usage event; dropped the held limit hit (late error)",
    "{n} 小时额度已满": "{n}-hour limit reached",
    "续答跳过（线程 {id}）：{why}": "Resume skipped (thread {id}): {why}",
    "主线程尾部没有 usage_limit_exceeded 的失败轮次": "no usage_limit_exceeded failed turn at the end of the main thread",
    "失败轮次之后已有新 turn 启动（可能已手动继续）": "a new turn started after the failed one (probably continued manually)",
    "任务被中断（线程 {id}）": "Task interrupted (thread {id})",
    "槽 {slot} 标为已耗尽（{why}），重置时间 {reset}，挡到 {until}": "Slot {slot} marked used up ({why}), resets {reset}, blocked until {until}",
    "（估算）": " (estimated)",
    "槽 {slot} 额度已恢复（{win} 已用 {pct}），解除耗尽标记": "Slot {slot} usage is back ({win} {pct} used); cleared the used-up mark",
    "守护进程启动（v{v}）：{rest}": "Daemon started (v{v}): {rest}",
    "守护进程启动：{rest}": "Daemon started: {rest}",
    "ChatGPT 打开对话时跳到了最前面，已隐藏，回到原来的窗口": "ChatGPT jumped to the front when opening the conversation; hid it and returned to your window",
    "检测到额度用完（{why}）：{email}（槽 {slot}）→ 槽 {to}": "Usage limit detected ({why}): {email} (slot {slot}) → slot {to}",
    "engine.py --slot {slot} 返回码 {rc}：{out}": "engine.py --slot {slot} exit code {rc}: {out}",
    "已切到槽 {slot}": "Switched to slot {slot}",
    "任务停滞自动恢复：第 {n} 次干预（线程 {id}）": "Stalled task auto-recovery: intervention {n} (thread {id})",
    "停滞干预：steer 未成功（{err}），改走开新轮次": "Stall intervention: steer failed ({err}); starting a new turn instead",
    "停滞干预失败（线程 {id}）：{err}": "Stall intervention failed (thread {id}): {err}",
    "任务疑似停滞：线程 {id} 已 {n} 分钟 无新进展": "Task may be stuck: thread {id} has made no progress for {n} min",
    "续答成功：已请 App 在线程 {id} 里继续（新 turn {turn}）": "Resumed: asked the app to continue in thread {id} (new turn {turn})",
    "续答进入延长重试：{rest}": "Resume moved to extended retries: {rest}",
    "全部账号都未到重置时间，进入等待：最早 {at} 解挡，届时自动继续切号": "No account has reset yet; waiting. The earliest unblocks at {at}, then switching resumes",
    "等待到点，自动恢复切号：{email}（槽 {slot}）→ 槽 {to}": "Wait over, switching resumes: {email} (slot {slot}) → slot {to}",
    "会话页点了「暂停」：{ids}，{n} 个正在跑的去停下": "Pause clicked on the Sessions page: {ids}; stopping {n} running",
    "切换 {old} → {new} (槽 {slot})": "Switch {old} → {new} (slot {slot})",
    "激活已有窗口 {slot} ({email})": "Activated the existing window {slot} ({email})",
    "为切换到 {slot} 自动退出了 {email}": "Signed out {email} automatically to switch to {slot}",
    "切换到 {slot}（{email}）—— profile 模式，未改 auth.json": "Switched to {slot} ({email}) — profile mode, auth.json unchanged",
    "添加账号被取消": "Adding an account was cancelled",
    "自动登出 rc={rc} auth存在={ex}": "Auto sign-out rc={rc}, auth exists={ex}",
    "已发起 codex login": "Started codex login",
    "添加完成，拉起 ChatGPT（槽 {slot}）": "Added, launching ChatGPT (slot {slot})",
    "自动切号关闭": "Auto-switch off",
    "自动切号开启": "Auto-switch on",
    "同步账号目录：{p} 个邮箱、{w} 个空间，新消息 {n} 条，{e} 个出错": "Synced account directory: {p} emails, {w} workspaces, {n} new messages, {e} errors",
    "槽 {slot} ({email}) 起算 {n} 小时窗口：已发出请求": "Slot {slot} ({email}) started the {n}-hour window: request sent",
}
_lang_cache = ["", -1.0]       # [语言, autoswitch.json 的修改时间]


def lang():
    try:
        m = os.stat(CONFIG).st_mtime
    except OSError:
        m = 0.0
    if m != _lang_cache[1]:
        c = read_json(CONFIG, {})
        _lang_cache[:] = ["en" if isinstance(c, dict) and c.get("lang") == "en" else "zh", m]
    return _lang_cache[0]


def t(s, /, **kw):
    """按界面语言取一句话；没有译文就用中文原文"""
    if lang() == "en":
        s = EN.get(s, s)
    return s.format(**kw) if kw else s


@contextlib.contextmanager
def file_lock(name):
    """跨进程互斥（App 和守护进程会同时写同一个文件）"""
    os.makedirs(P, exist_ok=True)
    with open(os.path.join(P, name + ".lock"), "w") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


# ---------- 凭证解析 ----------
def jwt_claims(tok):
    """解 JWT 的 payload，失败返回 {}"""
    try:
        b = tok.split(".")[1]
        b += "=" * (-len(b) % 4)
        return json.loads(base64.urlsafe_b64decode(b))
    except Exception:
        return {}


def jwt_exp(tok):
    """取 JWT 的 exp 时间戳，取不到返回 None"""
    return jwt_claims(tok).get("exp")


def info(path):
    """从 auth.json 解出 {acct, user, email, plan, days}；解析失败返回 None

    acct 是 workspace id，user 是登录的那个人：同一个团队空间里的不同成员 acct 相同、user 不同，
    所以「是不是同一个账号」要两个都比（见 same_account）。
    """
    try:
        tok = read_json(path, {})["tokens"]
        c = jwt_claims(tok["id_token"])
        a = c.get("https://api.openai.com/auth", {})
        until = a.get("chatgpt_subscription_active_until") or ""
        days = -1
        if until:
            try:
                end = datetime.datetime.fromisoformat(until.replace("Z", "+00:00"))
                days = (end - datetime.datetime.now(datetime.timezone.utc)).days
            except Exception:
                days = -1
        return {
            "acct":  tok.get("account_id") or a.get("chatgpt_account_id"),
            "user":  a.get("chatgpt_user_id") or a.get("user_id") or c.get("sub") or (c.get("email") or "").lower(),
            "email": c.get("email"),
            "plan":  a.get("chatgpt_plan_type"),
            "days":  days,          # 订阅剩余天数，-1 表示未知
        }
    except Exception:
        return None


def slots():
    """列出所有账号槽（按字母顺序，也就是自动切号的顺序）

    槽位文件名只能是单个大写字母：目录里还有各种配置/状态 json，旧版用黑名单排除，
    漏一个（比如 autoswitch_state.json）就会被当成一个「凭证异常」的账号。
    """
    if not os.path.isdir(P):
        return []
    return sorted(f[:-5] for f in os.listdir(P)
                  if len(f) == 6 and f.endswith(".json") and f[0] in SLOTPOOL)


def slot_path(s):
    return os.path.join(P, f"{s}.json")


def names():
    return read_json(NAMES, {})


def save_names(d):
    write_json(NAMES, d)


def lastused():
    return read_json(LASTUSED, {})


def mark_exit(slot):
    """记录某个槽位被切走的时刻，用于展示"""
    if not slot:
        return
    d = lastused()
    d[slot] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        write_json(LASTUSED, d)
    except Exception:
        pass


def same_account(a, b):
    """两份凭证是不是同一个账号：同一个 workspace 且同一个人。

    以前只比 workspace id，同一个团队空间里的两个成员会被当成同一个：添加第二个成员时报
    「已在槽位 X」、当前账号标错，切号时还会把新成员的凭证存回别人的槽位。
    """
    return bool(a and b and a.get("acct") and a["acct"] == b.get("acct") and a.get("user") == b.get("user"))


def find_slot(who):
    """按凭证（info() 的结果）找它所在的槽位：workspace 和人都要对上"""
    if not who or not who.get("acct"):
        return None
    for s in slots():
        if same_account(info(slot_path(s)), who):
            return s
    return None


def current_slot():
    """auth.json 当前对应的槽位，对不上返回 None"""
    cur = info(AUTH)
    return find_slot(cur)


def udd_for(slot):
    """每个槽位一个独立浏览器 profile

    桌面端的网页登录态在 profile 里，auth.json 只管 Codex 那一侧，两者必须成对，
    否则会出现「凭证是 A、会话是 B」→ 界面显示未登录。
    """
    return os.path.expanduser(f"~/Library/Application Support/ChatGPT-{slot}/udd")


def needs_login(path):
    """这一槽是否必须人工重新登录：没有 refresh_token，或刷新时被服务端吊销"""
    d = read_json(path, None)
    if d is None:
        return True
    tok = d.get("tokens") or {}
    if not tok.get("refresh_token"):
        return True
    # 重新登录后 id_token 会换新，旧的 refresh_failed 标记作废，以 token 实际状态为准
    exp = jwt_exp(tok.get("id_token", ""))
    if exp and exp > time.time():
        return False
    return bool(d.get("refresh_failed"))


# ---------- ChatGPT 实例控制 ----------
def running():
    """正在运行的 ChatGPT 主进程 PID 列表"""
    if DEMO:
        return ["0"]                       # 演示里当它在跑
    r = subprocess.run(["/bin/ps", "-eo", "pid,command"], capture_output=True, text=True)
    return [l.split()[0] for l in r.stdout.splitlines()
            if APP in l and "Helper" not in l]


def quit_app(timeout=15):
    """退出 ChatGPT：先 SIGTERM（Electron 照常走退出流程，不需要「自动化」授权），
    超时再 SIGKILL。返回是否已完全退出"""
    if not running():
        return True
    for pid in running():
        subprocess.run(["/bin/kill", "-TERM", pid], capture_output=True)
    for _ in range(timeout):
        if not running():
            return True
        time.sleep(1)
    for pid in running():
        subprocess.run(["/bin/kill", "-9", pid], capture_output=True)
    time.sleep(2)
    return not running()


def launch(slot, background=False):
    """用槽位自己的 profile 启动 ChatGPT；background=True 时不把它叫到前台（open -g）

    走 LaunchServices（open -a）而不是直接 exec 二进制：这样 App 正常登记，
    之后的 codex:// 深链会交给这个实例，而不是另起一个默认 profile 的实例；
    权限弹窗也记在 ChatGPT 自己头上，而不是记在调用方（Python）头上。
    """
    os.makedirs(udd_for(slot), exist_ok=True)
    subprocess.run(["/usr/bin/open"] + (["-g"] if background else []) + ["-a", APP_BUNDLE, "--args",
                    f"--user-data-dir={udd_for(slot)}"],
                   capture_output=True, timeout=30)


def activate():
    """把已在运行的 ChatGPT 叫到前台（不会另开实例）"""
    subprocess.run(["/usr/bin/open", "-b", CHATGPT_ID], capture_output=True)


def frontmost():
    """最前面那个 App 的 bundle id（lsappinfo，不需要任何授权）；取不到返回空串"""
    try:
        asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
        out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "bundleid", asn],
                             capture_output=True, text=True, timeout=5).stdout
        m = re.search(r'bundleID="([^"]+)"', out)
        return m.group(1) if m else ""
    except Exception:
        return ""


def give_back(prev, seconds):
    """后台切号 / 深链之后的 seconds 秒内盯着前台：ChatGPT 一跳到最前面（它启动、打开对话时会自己
    show + focus 窗口，open -g 拦不住），就把焦点还给之前用户在用的 prev。

    只还一次：之后用户自己点 ChatGPT 不能再被拽走。还焦点而不是隐藏 ChatGPT：隐藏会让它的窗口
    整个消失，看起来像「一会切过来一会又没了」。返回是否还过焦点。"""
    if not prev or prev == CHATGPT_ID or not os.access(APP_BIN, os.X_OK):
        return False
    end = time.time() + seconds
    while time.time() < end:
        if frontmost() == CHATGPT_ID:
            try:
                r = subprocess.run([APP_BIN, "--activate-app", prev], capture_output=True, timeout=10)
                if r.returncode != 0:          # 原来的 App 已经退出了：退一步把 ChatGPT 藏起来
                    subprocess.run([APP_BIN, "--hide-app", CHATGPT_ID], capture_output=True, timeout=10)
            except Exception:
                return False
            return True
        time.sleep(0.15)
    return False


def backup_auth():
    """覆盖 auth.json 前先备份，滚动保留最近 20 份"""
    if not os.path.exists(AUTH):
        return
    os.makedirs(BACKUP, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(AUTH, os.path.join(BACKUP, f"auth-{stamp}.json"))
    for f in sorted(os.listdir(BACKUP))[:-20]:
        os.remove(os.path.join(BACKUP, f))


def stash_current():
    """把当前凭证存回它所属的槽，保住 App 运行期间刷新过的 token"""
    s = find_slot(info(AUTH))
    if s:
        shutil.copy2(AUTH, slot_path(s))


# ---------- 凭证刷新 ----------
TOKEN_URL  = "https://auth.openai.com/oauth/token"
CLIENT_IDS = ["app_EMoamEEZ73f0CkXaXp7hrann",
              "app_69a1d78e929881919bba0dbda1f6436d"]


def refresh_slot(path):
    """用 refresh_token 换一份新的 id_token 并写回槽位文件

    id_token 只活 1 小时，而槽位快照是切走那一刻存下来的，隔一小时以上再切回来
    必然是死的 —— 不刷新就会「切回之前登录的账号提示登录失效」。

    ⚠️ 刷新成功服务端会轮换 refresh_token，必须立刻原子写回，丢了就只能重新登录。
    失败不阻断切换（不比现状更差）。
    """
    data = read_json(path, None)
    if data is None:
        return False, t("读取失败")
    tokens = data.get("tokens") or {}
    rt = tokens.get("refresh_token")
    if not rt:
        return False, t("没有 refresh_token，需重新登录")

    exp = jwt_exp(tokens.get("id_token", ""))
    left = (exp - time.time()) / 60 if exp else -999
    if left > 5:
        return True, t("仍有效（剩 {left:.0f} 分钟），跳过", left=left)

    last = ""
    for cid in CLIENT_IDS:
        body = json.dumps({"client_id": cid, "grant_type": "refresh_token",
                           "refresh_token": rt, "scope": "openid profile email"}).encode()
        req = urllib.request.Request(TOKEN_URL, data=body, headers={
            "Content-Type": "application/json", "User-Agent": "Codex-Desktop"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                got = json.loads(r.read())
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
            continue
        except Exception as e:
            return False, t("网络错误 {name}", name=type(e).__name__)
        if not got.get("id_token"):
            last = t("响应缺 id_token")
            continue

        data.pop("refresh_failed", None)
        shutil.copy2(path, path + ".pre-refresh")     # 轮换前留一份
        tokens["id_token"] = got["id_token"]
        if got.get("access_token"):
            tokens["access_token"] = got["access_token"]
        if got.get("refresh_token"):
            tokens["refresh_token"] = got["refresh_token"]
        data["tokens"] = tokens
        data["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime())
        write_json(path, data)
        return True, t("已刷新")

    # 401/400 表示 refresh_token 已被吊销，打个持久标记让 UI 标红提示重新登录
    if "401" in last or "400" in last:
        try:
            data["refresh_failed"] = True
            write_json(path, data)
        except Exception:
            pass
    return False, t("刷新失败（{last}），需要重新登录", last=last)


# ---------- 切号 ----------
def switch(slot, force=False, background=False):
    """切到指定槽位，返回 (成功?, 结果 dict)。

    同一个 workspace 且 App 在跑：只把窗口叫到前台；force=True 时一律退出重开
    （点当前账号 = 干净重启一次，绕开 ChatGPT 偶发的卡死/白屏）。
    background=True（后台服务自动切号）：重开时不把 ChatGPT 叫到前台，同账号也不去激活它。
    """
    want = info(slot_path(slot))
    if not want:
        return False, {"err": t("槽位 {slot} 不存在或凭证损坏，建议删掉重新添加", slot=slot)}
    cur = info(AUTH)
    if running() and same_account(cur, want) and not force:
        if not background:
            activate()
        return True, {"email": want["email"], "activated": True}

    prev = find_slot(cur)
    if not quit_app():
        return False, {"err": t("ChatGPT 没能退出，请手动 Cmd+Q 后重试")}
    # 退出之后再存回：App 退出前可能刚刷新过 token
    stash_current()
    backup_auth()
    mark_exit(prev)

    ok_r, msg_r = refresh_slot(slot_path(slot))
    log(t("槽 {slot} 凭证刷新：{msg}", slot=slot, msg=msg_r))
    shutil.copy2(slot_path(slot), AUTH)
    launch(slot, background)
    log(t("切换 {a} → {b} (槽 {slot} / {acct})", a=cur["email"] if cur else t("无"), b=want["email"],
          slot=slot, acct=(want["acct"] or "")[:8]))
    record_switch(slot, want["email"])
    return True, {"email": want["email"]}


# ---------- 切号历史：对话列表据此推断每个对话跑在哪个账号 ----------
HISTORY_MAX = 1000
_SWITCH_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+(?:切换|Switched) .* → (\S+) \((?:槽|slot) ([A-Z])[ )]")  # i18n-ignore


def _history_from_log():
    """第一次还没有 switch_history.json 时，从 manager.log 的「切换 a → b (槽 X / …)」行回填
    （更早的日志是「(槽 X)」，没有 workspace 前缀，一并认）"""
    res = []
    try:
        with open(LOG, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = _SWITCH_LINE.match(line)
                if m:
                    at = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
                    res.append({"at": at, "slot": m.group(3), "email": m.group(2)})
    except OSError:
        pass
    return res


def _load_history():
    """调用方须持有 history 锁"""
    if not os.path.exists(HISTORY):
        h = _history_from_log()[-HISTORY_MAX:]
        write_json(HISTORY, h)
        log(t("切号历史：从 manager.log 回填 {n} 条", n=len(h)))
        return h
    return read_json(HISTORY, [])


def switch_history():
    """[{at, slot, email}]，按时间先后"""
    with file_lock("history"):
        h = _load_history()
    return sorted(h, key=lambda x: x.get("at") or 0)


def record_switch(slot, email):
    """切号成功后追加一条，只留最近 HISTORY_MAX 条；写失败不影响切号"""
    try:
        with file_lock("history"):
            h = _load_history()
            h.append({"at": time.time(), "slot": slot, "email": email or ""})
            write_json(HISTORY, h[-HISTORY_MAX:])
    except Exception as e:
        log(t("切号历史写入失败 {name}: {e}", name=type(e).__name__, e=e))


def slot_at(hist, t):
    """t 时刻在用的账号 → (槽, 邮箱)：历史里 at ≤ t 的最后一条；没有返回 ("", "")"""
    i = bisect.bisect_right([x.get("at") or 0 for x in hist], t) - 1
    return (hist[i].get("slot") or "", hist[i].get("email") or "") if i >= 0 else ("", "")


# ---------- 额度 ----------
USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"


def load_quota():
    return read_json(QUOTA, {})


def merge_quota(slot, entry):
    """把一条额度记录并进缓存，返回合并后的该槽记录"""
    with file_lock("quota"):
        q = load_quota()
        cur = q.get(slot) or {}
        cur.update(entry)
        q[slot] = cur
        write_json(QUOTA, q)
    return cur


def _window(w):
    """服务端的窗口结构 → {used, reset_at, window}"""
    if not isinstance(w, dict) or w.get("used_percent") is None:
        return None
    return {"used": float(w["used_percent"]),
            "reset_at": int(w.get("reset_at") or 0),
            "window": int(w.get("limit_window_seconds") or 0)}


def split_windows(a, b):
    """服务端给的两个额度窗口 → (5 小时那个, 每周那个)，按窗口长度分，不按位置。

    大多数套餐 primary 是 5 小时、secondary 是每周；但有的套餐（比如 self_serve_business_prolite）
    没有 5 小时限额，只有每周额度，它会出现在 primary 位置上，按位置读就把每周当成了 5 小时。
    长度未知的窗口按原来的位置算。"""
    short = long_ = None
    for pos, w in enumerate((a, b)):
        if not w:
            continue
        n = w.get("window") or 0
        if (n > 86400 if n else pos == 1):
            long_ = long_ or w
        else:
            short = short or w
    return short, long_


def slot_token(slot):
    """某槽可用的 access_token → (token, account_id, 错误说明)

    当前账号读 auth.json（App 运行中可能刚刷新过 token，槽位快照里那份可能已被轮换），
    其余读槽位快照。这里绝不刷新凭证：刷新会轮换 refresh_token，不值得为了查一眼
    额度冒这个险。access_token 有效期约 10 天，每次切号都会刷新。
    """
    src = slot_path(slot)
    want, cur = info(src), info(AUTH)
    if same_account(want, cur):
        src = AUTH
    tok = (read_json(src, {}) or {}).get("tokens") or {}
    at = tok.get("access_token") or ""
    acct = tok.get("account_id") or (want or {}).get("acct") or ""
    exp = jwt_exp(at)
    if not at or (exp and exp < time.time()):
        return "", acct, t("凭证过期，切到这个账号一次即可刷新")
    return at, acct, ""


def _pin_proxy():
    """launchd 起的进程没有终端里的 HTTP(S)_PROXY，urllib 会改读系统代理设置，
    并按系统的「例外列表」判断要不要绕过。代理软件的 fake-ip DNS 会把 chatgpt.com
    解析到 198.18.x.x，而这个网段在例外列表里 → 绕过代理直连 → Cloudflare 对
    accounts/* 返回 403 网页。所以没有环境变量时，把系统代理抄进环境变量，
    绕过判断也随之改用环境变量（只绕过本机地址）。
    （是否真由这条路径引起 403 没有证实；后来确认 403 主要是请求过密，这里只是保证
    launchd 里和终端里走同一条线路。）"""
    if any(os.environ.get(k) for k in ("https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY")):
        return
    sys_proxies = urllib.request.getproxies()
    for scheme in ("http", "https"):
        if sys_proxies.get(scheme):
            os.environ[f"{scheme}_proxy"] = sys_proxies[scheme]
    if sys_proxies:
        os.environ.setdefault("no_proxy", "localhost,127.0.0.1,::1,.local")


_pin_proxy()


def _no_network(*a, **k):
    raise urllib.error.URLError(t("演示模式不联网"))


if DEMO:
    urllib.request.urlopen = _no_network


def backend_get(path, token, acct, timeout=15):
    """GET chatgpt.com/backend-api/<path>，带 Codex 客户端的 UA

    wham/*、me、accounts/*、subscriptions 都能访问。短时间请求太密时 Cloudflare 会对
    非 wham 接口临时返回 403 网页，几分钟后恢复。失败抛 urllib 的异常。
    """
    req = urllib.request.Request("https://chatgpt.com/backend-api/" + path, headers={
        "Authorization": f"Bearer {token}", "ChatGPT-Account-Id": acct,
        "User-Agent": "codex_cli_rs", "originator": "codex_cli_rs",
        "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def fetch_usage(slot):
    """联网查一个槽位的实时额度（Codex 自己 /status 用的同一个接口），并进缓存后返回"""
    now = time.time()
    at, acct, err = slot_token(slot)
    if err:
        return merge_quota(slot, {"error": err, "error_at": now})
    try:
        d = backend_get("wham/usage", at, acct)
    except urllib.error.HTTPError as e:
        return merge_quota(slot, {"error": t("查询失败 HTTP {code}", code=e.code), "error_at": now})
    except Exception as e:
        return merge_quota(slot, {"error": t("网络错误 {name}", name=type(e).__name__), "error_at": now})
    rl = d.get("rate_limit") or {}
    short, week = split_windows(_window(rl.get("primary_window")), _window(rl.get("secondary_window")))
    return merge_quota(slot, {
        "at": now, "src": "api",
        "primary": short,                  # 5 小时窗口；没有 5 小时限额的套餐为 None
        "secondary": week,
        "reached": bool(rl.get("limit_reached")) or rl.get("allowed") is False,
        # 撞限类型：rate_limit_reached = 5 小时 / 每周额度；workspace_owner_credits_depleted = 空间 credits 用完
        "limit_type": (d.get("rate_limit_reached_type") or {}).get("type") or "",
        "resets": (d.get("rate_limit_reset_credits") or {}).get("available_count") or 0,
        "error": "", "error_at": 0,
    })


def backend_post(path, token, acct, body, timeout=15):
    """POST JSON 到 chatgpt.com/backend-api/<path>，头和 backend_get 一样。失败抛 urllib 的异常"""
    req = urllib.request.Request("https://chatgpt.com/backend-api/" + path,
                                 data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {token}", "ChatGPT-Account-Id": acct,
        "User-Agent": "codex_cli_rs", "originator": "codex_cli_rs",
        "Accept": "application/json", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _live_token(slot):
    """主动操作（用券、起算窗口）用的 token → (token, account_id, 错误说明)

    和 slot_token 不同：非当前槽的快照过期了就先刷新再取（refresh_slot 会原子写回轮换后
    的 refresh_token）。当前槽绝不在这里刷新 —— 它的 refresh_token 在 auth.json 里归 App
    管，这边一轮换 App 就掉线。
    """
    at, acct, err = slot_token(slot)
    if err and slot != current_slot():
        ok, msg = refresh_slot(slot_path(slot))
        log(t("槽 {slot} 凭证刷新：{msg}", slot=slot, msg=msg))
        if ok:
            at, acct, err = slot_token(slot)
    return at, acct, err


# ---------- 额度重置券 ----------
# 接口取自 ChatGPT 桌面 App 源码。consume 的返回 {code, credit, windows_reset}：
# code = reset 已重置、already_redeemed 这张之前用过；券 id 不存在时是 HTTP 200 + no_credit（不扣券）。
RESET_CREDITS = "wham/rate-limit-reset-credits"


def _credits(raw):
    """接口里的券列表 → 目录里存的精简结构"""
    return [{"id": c.get("id") or "", "title": c.get("title") or "", "status": c.get("status") or "",
             "expiresAt": iso(c.get("expires_at")), "grantedAt": iso(c.get("granted_at"))}
            for c in (raw or {}).get("credits") or []]


def _update_slot_credits(slot, mail, token, acct):
    """用券后重新拉一次这个槽位的券列表，写回 directory.json 的 slotCredits

    券跟着账号（空间）走：同一邮箱的两个空间各有各的券、id 也不同，拿别的空间的券 id 去用会返回 no_credit。
    """
    raw, err = _get(RESET_CREDITS, token, acct)
    if raw is None:
        log(t("{mail} 用券后刷新券列表失败 {err}，等下次同步", mail=mail, err=err))
        return
    with file_lock("directory"):
        d = load_directory()
        d.setdefault("slotCredits", {})[slot] = _credits(raw)
        write_json(DIRECTORY, d)


def reset_credit(slot, credit_id=""):
    """用一张额度重置券（不可逆）→ (成功?, 错误说明, 服务端 code, 刷新后的额度或 None)

    不指定券就用这个账号可用券里最早过期的那张。
    """
    i = info(slot_path(slot))
    if not i:
        return False, t("槽位 {slot} 不存在或凭证损坏", slot=slot), "", None
    at, acct, err = _live_token(slot)
    if err:
        return False, err, "", None
    if not credit_id:
        raw, e = _get(RESET_CREDITS, at, acct)
        if raw is None:
            return False, t("读取重置券失败 {e}", e=e), "", None
        avail = sorted((c for c in raw.get("credits") or [] if c.get("status") == "available" and c.get("id")),
                       key=lambda c: iso(c.get("expires_at")) or float("inf"))
        if not avail:
            return False, t("这个账号没有可用的重置券"), "", None
        credit_id = avail[0]["id"]
    try:
        r = backend_post(RESET_CREDITS + "/consume", at, acct,
                         {"credit_id": credit_id, "redeem_request_id": str(uuid.uuid4())})
    except urllib.error.HTTPError as e:
        log(t("槽 {slot} 使用重置券失败 HTTP {code}", slot=slot, code=e.code))
        return False, t("使用失败 HTTP {code}", code=e.code), "", None
    except Exception as e:
        log(t("槽 {slot} 使用重置券失败 {name}", slot=slot, name=type(e).__name__))
        return False, t("网络错误 {name}", name=type(e).__name__), "", None
    code = r.get("code") or ""
    log(t("槽 {slot} ({email}) 使用重置券 {credit}：{code}，重置了 {n} 个窗口", slot=slot, email=i["email"],
          credit=credit_id[:16], code=code or t("无返回码"), n=r.get("windows_reset") or 0))
    if code not in ("reset", "already_redeemed"):
        return False, t("没有重置（服务端返回 {code}）", code=code or t("空")), code, None
    usage = fetch_usage(slot)
    _update_slot_credits(slot, i["email"], at, acct)
    p = usage.get("primary") or {}
    push_event("quota", t("{email} 用了一张额度重置券", email=i["email"]) if code == "reset"
               else t("{email} 的这张重置券之前已用过", email=i["email"]),
               t("槽 {slot} · 5 小时额度已用 {used:g}%", slot=slot, used=p.get("used", 0)) if p
               else t("槽 {slot}", slot=slot), "info", slot)
    return True, "", code, usage


# ---------- 起算 5 小时窗口 ----------
# 没用过的账号，wham/usage 给的 5 小时重置时刻永远是「现在 + 5h」，要真发一次模型请求
# 窗口才开始计时。直接打 Codex 用 ChatGPT 登录时走的 codex/responses（流式、store=false）。
CODEX_RESPONSES = "https://chatgpt.com/backend-api/codex/responses"


def _warmup_models():
    """起算窗口用的模型：优先 Codex 模型列表里的小模型（luna / mini），再退到 config.toml 里的默认模型"""
    cache = read_json(os.path.expanduser("~/.codex/models_cache.json"), {})
    listed = [m.get("slug") for m in (cache.get("models") or []) if m.get("visibility") == "list" and m.get("slug")]
    small = [m for m in listed if "luna" in m or "mini" in m]
    conf = ""
    try:
        with open(os.path.expanduser("~/.codex/config.toml"), encoding="utf-8") as f:
            m = re.search(r'^model\s*=\s*"([^"]+)"', f.read(), re.M)
            conf = m.group(1) if m else ""
    except OSError:
        pass
    res = []
    for m in small + [conf] + listed[:1]:
        if m and m not in res:
            res.append(m)
    return res


def _ping_model(token, acct, model, timeout=90):
    """发一句「hi」并把流读到 response.completed → (成功?, 错误说明)"""
    body = {"model": model, "instructions": "Reply with one word.",
            "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]}],
            "tools": [], "tool_choice": "auto", "parallel_tool_calls": False,
            "reasoning": {"effort": "low"}, "store": False, "stream": True, "include": []}
    req = urllib.request.Request(CODEX_RESPONSES, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {token}", "ChatGPT-Account-Id": acct,
        "User-Agent": "codex_cli_rs", "originator": "codex_cli_rs",
        "Accept": "text/event-stream", "Content-Type": "application/json",
        "session_id": str(uuid.uuid4())})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            try:
                ev = json.loads(line[5:])
            except ValueError:
                continue
            typ = ev.get("type") or ""
            if typ == "response.completed":
                return True, ""
            if typ in ("response.failed", "response.incomplete", "error"):
                e = (ev.get("response") or {}).get("error") or ev.get("error") or {}
                return False, f"{typ} {e.get('code') or e.get('message') or ''}".strip()
    return False, t("流提前结束，没有 response.completed")


def start_window(slot):
    """让某账号的 5 小时窗口开始计时 → (成功?, 错误说明, 刷新后的额度或 None)"""
    i = info(slot_path(slot))
    if not i:
        return False, t("槽位 {slot} 不存在或凭证损坏", slot=slot), None
    at, acct, err = _live_token(slot)
    if err:
        return False, err, None
    ok, err = False, t("没有可用的模型")
    t0 = int(time.time())
    for model in _warmup_models():
        try:
            ok, err = _ping_model(at, acct, model)
        except urllib.error.HTTPError as e:
            ok, err = False, f"{model} HTTP {e.code}"
            if e.code in (400, 404):            # 这个账号用不了这个模型，换下一个
                continue
        except Exception as e:
            ok, err = False, t("网络错误 {name}", name=type(e).__name__)
        break
    log(t("槽 {slot} ({email}) 起算 5 小时窗口：已发出请求（{model}）", slot=slot, email=i["email"], model=model) if ok
        else t("槽 {slot} ({email}) 起算 5 小时窗口：失败 {err}", slot=slot, email=i["email"], err=err))
    if ok:
        # 刚起算时服务端给的重置时间仍约等于「查询时刻 + 5h」，界面单看它分不出开没开始，记下起算时刻
        merge_quota(slot, {"started_at": t0})
    usage = fetch_usage(slot)
    return ok, err, usage


def window_untouched(entry, now):
    """5 小时窗口还没开始计时（和 App 里 UsageWindow.untouched 同一套判断）

    没用过的账号，服务端给的重置时间永远是「查询时刻 + 5h」；本机点过「开始计时」的，
    started_at 落在当前窗口里就算已开始（刚起算的几分钟里重置时间仍约等于查询时刻 + 5h）。
    """
    entry = entry or {}
    w, at = entry.get("primary"), entry.get("at") or 0
    if not w or w.get("used", 0) > 0 or not at:
        return False
    win, reset = w.get("window") or 0, w.get("reset_at") or 0
    if win <= 0 or reset <= now:                  # 重置时刻已过：缓存是旧的，等下一次刷新再判断
        return False
    if (entry.get("started_at") or 0) >= reset - win - 60:
        return False
    return reset - at >= win - 120


START_FRESH = 1200          # 额度数据 20 分钟内查过的才算数


def start_candidates(now):
    """该自动起算 5 小时窗口的槽位（字母序）：窗口没开始、数据新鲜、现在能用（本周没用完、
    没被临时挡住）、不用重新登录"""
    q = load_quota()
    res = []
    for s in slots():
        e = q.get(s) or {}
        if e.get("error") or now - (e.get("at") or 0) > START_FRESH:
            continue
        if available_at(e, now) != 0 or needs_login(slot_path(s)):
            continue
        if window_untouched(e, now):
            res.append(s)
    return res


def window_full(w, now):
    """这个窗口此刻是否用满（reset_at 已过就算已重置）"""
    return bool(w) and w.get("used", 0) >= 100 and (w.get("reset_at") or 0) > now


def available_at(entry, now):
    """某槽什么时候可用：0 = 现在可用；>0 = 到那个时刻恢复；None = 没有数据

    依据：两个窗口里用满的那个的重置时间、守护进程因报错临时挡住的 block_until，
    以及服务端「limit_reached」但两个窗口都没满（比如 team 空间 credits 用完）的情况。
    """
    entry = entry or {}
    t = 0
    for k in ("primary", "secondary"):
        w = entry.get(k)
        if window_full(w, now):
            t = max(t, w["reset_at"])
    if entry.get("reached") and not t and now - (entry.get("at") or 0) < 600:
        t = now + 1800                     # 原因不明的不可用：半小时后再联网确认
    if (entry.get("block_until") or 0) > now:
        t = max(t, entry["block_until"])
    if t:
        return t
    if not entry.get("primary") and not entry.get("secondary"):
        return None
    return 0


# ---------- 账号目录：空间、订阅、成员（全部走接口） ----------
#
# 以前以为 accounts/* 只能在浏览器里调（用浏览器 UA 会被 Cloudflare 拦成 403），
# 其实带上 Codex 自己的 UA（codex_cli_rs）全部都能直接调：
#   me                              用户资料
#   accounts/check/v4-2023-04-27    这个用户所在的全部空间 + 每个空间的订阅（续费 / 到期）
#   subscriptions?account_id=       席位用量、计费周期
#   accounts/{id}/users | invites   成员（含加入时间）/ 待接受邀请
#   wham/rate-limit-reset-credits   免费额度重置券（含过期时间）
NOTICE_DAYS = 3


def iso(s):
    """ISO 时间 → epoch；python3.9 的 fromisoformat 不认 Z，也只认 6 位小数"""
    if not s:
        return 0
    try:
        s = s.replace("Z", "+00:00")
        head, _, tz = s.partition("+")
        if "." in head:
            a, b = head.split(".", 1)
            head = a + "." + (b + "000000")[:6]
        return datetime.datetime.fromisoformat(head + ("+" + tz if tz else "")).timestamp()
    except ValueError:
        return 0


def load_directory():
    return read_json(DIRECTORY, {"at": 0, "people": [], "workspaces": [], "errors": []})


# ---------- Cloudflare 拦截时借 App 里的 WebKit 发请求 ----------
#
# 2026-10-21 起 chatgpt.com 对非浏览器客户端的 accounts/*、subscriptions 一律返回 Cloudflare 验证页
# （403 + cf-mitigated: challenge），换 UA 也不行；me、wham/* 不受影响。浏览器里同样的请求能过，
# 所以被拦时改由 `ChatGPTAccounts --web-fetch` 在不显示的 WKWebView 里发（协议见 App/WebFetch.swift）。
# 一次同步里只起一个这样的进程，同步完关掉。
_web = {"proc": None, "failed": False, "cf_until": 0, "n": 0}      # n：这次同步里经 WebKit 取到的请求数
_web_lock = threading.Lock()


def _web_start():
    """起 WebKit 助手，等它打开 chatgpt.com；失败返回 None 并记下这次同步不再试"""
    p = _web["proc"]
    if p and p.poll() is None:
        return p
    if _web["failed"] or DEMO or not os.access(APP_BIN, os.X_OK):
        return None
    try:
        p = subprocess.Popen([APP_BIN, "--web-fetch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, bufsize=1)
        r = _web_line(p, 50)
        if r and r.get("ready"):
            _web["proc"] = p
            return p
        log(t("WebKit 取数据没起来：{err}", err=(r or {}).get("error") or t("没有响应")))
        p.kill()
    except Exception as e:
        log(t("WebKit 取数据没起来：{err}", err=type(e).__name__))
    _web["failed"] = True
    return None


def _web_line(p, timeout):
    """读助手的一行 JSON，超时 / 退出返回 None"""
    if not select.select([p.stdout], [], [], timeout)[0]:
        return None
    line = p.stdout.readline()
    try:
        return json.loads(line) if line else None
    except ValueError:
        return None


def web_get(path, token, acct):
    """借 WebKit GET backend-api/<path> → (数据, 错误文字)；助手不可用返回 (None, None)"""
    with _web_lock:
        p = _web_start()
        if not p:
            return None, None
        try:
            p.stdin.write(json.dumps({"path": path, "token": token, "acct": acct}) + "\n")
            p.stdin.flush()
            r = _web_line(p, 30)
        except Exception:
            r = None
        if r is None:
            p.kill()
            _web["proc"] = None
            return None, t("WebKit 无响应")
    if r.get("status") == 200:
        try:
            d = json.loads(r.get("body") or "")
            _web["n"] += 1
            return d, ""
        except ValueError:
            return None, t("WebKit 返回的不是 JSON")
    return None, f"HTTP {r.get('status')}（WebKit）" if r.get("status") else f"WebKit：{r.get('body')}"


def web_close():
    with _web_lock:
        p, _web["proc"], _web["failed"], _web["n"] = _web["proc"], None, False, 0
    if p:
        try:
            p.stdin.close()
            p.wait(5)
        except Exception:
            p.kill()


def _get(path, token, acct):
    """backend_get，失败返回 (None, 错误文字)。被 Cloudflare 拦了就改用 WebKit，
    之后 10 分钟里非 wham 接口直接走 WebKit（反正会被拦，省一次必定失败的请求）"""
    if time.time() < _web["cf_until"] and not path.startswith("wham/"):
        d, err = web_get(path, token, acct)
        if err is not None:
            return d, err
    try:
        return backend_get(path, token, acct), ""
    except urllib.error.HTTPError as e:
        if e.code == 403 and e.headers.get("cf-mitigated"):
            _web["cf_until"] = time.time() + 600
            d, err = web_get(path, token, acct)
            if err is not None:
                return d, err
            return None, t("被 Cloudflare 拦截（HTTP 403）")
        return None, f"HTTP {e.code}"
    except Exception as e:
        return None, type(e).__name__


def _sub(ent, s):
    """订阅信息：v4 的 entitlement + subscriptions 接口（后者没权限时为 None）"""
    ent = ent or {}
    s = s or {}
    disc = ent.get("discount") or {}
    disc_text = ""
    if disc.get("amount"):
        cur = ent.get("billing_currency") or ""
        until = iso(disc.get("discount_expires_at"))
        disc_text = (t("每期减 {amount:g} {cur}，至 {date}", amount=disc["amount"], cur=cur,
                       date=time.strftime("%Y-%m-%d", time.localtime(until))) if until
                     else t("每期减 {amount:g} {cur}", amount=disc["amount"], cur=cur)).replace("  ", " ").strip()
    las = s.get("last_active_subscription") or {}
    return {
        "active": bool(ent.get("has_active_subscription")),
        "plan": ent.get("subscription_plan") or "",
        "renewsAt": iso(ent.get("renews_at")),
        "expiresAt": iso(ent.get("expires_at")),
        "cancelsAt": iso(ent.get("cancels_at")),
        "willRenew": bool(s.get("will_renew", las.get("will_renew", ent.get("cancels_at") is None))),
        "billing": ent.get("billing_period") or s.get("billing_period") or "",
        "currency": ent.get("billing_currency") or "",
        "activeStart": iso(s.get("active_start")),
        "seatsUsed": s.get("seats_in_use") or 0,
        "seatsTotal": s.get("seats_entitled") or 0,
        "discount": disc_text,
        "delinquent": bool(ent.get("is_delinquent") or s.get("is_delinquent")),
        "graceEnd": iso(ent.get("grace_period_end_timestamp")) if isinstance(ent.get("grace_period_end_timestamp"), str) else (ent.get("grace_period_end_timestamp") or 0),
        "platform": las.get("purchase_origin_platform") or "",
        "trial": bool(ent.get("trial")),
    }


def _members(wid, token):
    users, off, err = [], 0, ""
    while True:
        d, err = _get(f"accounts/{wid}/users?offset={off}&limit=100&query=", token, wid)
        if d is None:
            return None, err
        items = d.get("items") or []
        users += items
        off += len(items)
        if not items or off >= (d.get("total") or 0):
            break
    return [{"id": u.get("id") or "", "email": u.get("email") or "", "name": u.get("name") or "",
             "role": u.get("role") or "", "seat": u.get("seat_type") or "",
             "joined": iso(u.get("created_time")), "deactivatedAt": iso(u.get("deactivated_time"))}
            for u in users], ""


def sync_directory():
    """见 _sync_directory；无论成败，同步完都关掉可能起了的 WebKit 助手"""
    try:
        return _sync_directory()
    finally:
        web_close()


def _sync_directory():
    """联网拉一遍全部账号的空间、订阅、成员、重置券，写进 directory.json 并更新消息中心

    chatgpt.com 的 Cloudflare 对非浏览器客户端时不时会拦一阵 accounts/*（403 网页），
    所以并发压低，并且哪一项没拿到就沿用上次同步的结果，不拿空数据覆盖。
    """
    from concurrent.futures import ThreadPoolExecutor
    old = load_directory()
    old_ws = {w["id"]: w for w in old.get("workspaces", [])}
    old_people = {p["email"]: p for p in old.get("people", [])}
    errors = []
    mine, by_mail = {}, {}                     # workspace id → 槽；邮箱 → 槽
    for s in slots():
        i = info(slot_path(s)) or {}
        if i.get("acct"):
            mine.setdefault(i["acct"], []).append(s)
        if i.get("email"):
            by_mail.setdefault(i["email"], []).append(s)

    def per_person(mail):
        for s in by_mail[mail]:
            at, acct, err = slot_token(s)
            if not err:
                break
        else:
            return mail, None, f"{mail}：{err}"
        me, _ = _get("me", at, acct)
        v4, e2 = _get("accounts/check/v4-2023-04-27", at, acct)
        accounts = None
        if v4 is not None:
            accounts = [(a.get("account") or {}, a.get("entitlement")) for a in (v4.get("accounts") or {}).values()]
        else:
            # Codex 自己的接口不会被拦，至少拿到空间列表和角色；订阅沿用上次
            wc, _ = _get("wham/accounts/check", at, acct)
            if wc is None:
                return mail, None, t("{mail}：空间列表 {err}", mail=mail, err=e2)
            accounts = [({"account_id": a.get("id"), "name": a.get("name"), "structure": a.get("structure"),
                          "plan_type": a.get("plan_type"), "is_deactivated": a.get("is_deactivated"),
                          "account_user_role": a.get("account_user_role")}, None)
                        for a in wc.get("accounts") or []]
        return mail, {"token": at, "slot": s, "me": me, "accounts": accounts,
                      "partial": v4 is None}, ""

    with ThreadPoolExecutor(3) as ex:
        got = list(ex.map(per_person, sorted(by_mail)))

    people, ws = [], {}
    for mail, r, err in got:
        if err:
            errors.append(err)
            if mail in old_people:
                people.append(old_people[mail])
            continue
        if r["partial"]:
            errors.append(t("{mail}：订阅信息暂时拿不到，沿用上次", mail=mail))
        me = r["me"] or {}
        op = old_people.get(mail, {})
        people.append({
            "email": mail, "name": me.get("name") or op.get("name", ""), "userId": me.get("id") or op.get("userId", ""),
            "created": me.get("created") or op.get("created", 0),
            "mfa": bool(me.get("mfa_flag_enabled", op.get("mfa", False))),
            "country": me.get("country") or op.get("country", ""), "slots": by_mail[mail],
        })
        for acc, ent in r["accounts"]:
            wid = acc.get("account_id")
            if not wid:
                continue
            prev = old_ws.get(wid, {})
            w = ws.setdefault(wid, {
                "id": wid, "name": acc.get("name") or "", "structure": acc.get("structure") or "",
                "plan": acc.get("plan_type") or "",
                "planName": acc.get("plan_display_name") or prev.get("planName", ""),
                "deactivated": bool(acc.get("is_deactivated")),
                "created": iso(acc.get("created_time")) or prev.get("created", 0),
                "slots": mine.get(wid, []), "access": [],
                "sub": _sub(ent, None) if ent is not None else prev.get("sub") or _sub(None, None),
                "members": prev.get("members"), "membersAt": prev.get("membersAt", 0),
                "invites": prev.get("invites", []),
                "errors": [], "_tok": None, "_rank": 9})
            role = acc.get("account_user_role") or ""
            own = [x for x in mine.get(wid, []) if (info(slot_path(x)) or {}).get("email") == mail]
            w["access"].append({"email": mail, "role": role, "viaSlot": own[0] if own else r["slot"]})
            rank = {"account-owner": 0, "account-admin": 1, "admin": 1}.get(role, 5)
            if rank < w["_rank"]:                 # 用权限最高的那个身份去查订阅和成员
                w["_rank"], w["_tok"] = rank, r["token"]
                # 空间的套餐也以它看到的为准：v4 里的 plan_type / 显示名是「这个人的席位」，
                # 同一空间里 Pro Lite 席位的成员看到的是 self_serve_business_prolite / Business Premium
                if acc.get("plan_type"):
                    w["plan"] = acc["plan_type"]
                    w["planName"] = acc.get("plan_display_name") or ""

    def per_ws(w):
        tok = w["_tok"]
        team = w["structure"] == "workspace" and not w["deactivated"]
        # 席位只对团队有意义；个人空间省掉这次请求，免得触发 Cloudflare 限流
        s, e = _get(f"subscriptions?account_id={w['id']}", tok, w["id"]) if team else (None, "")
        if s is not None:
            w["sub"] = {**w["sub"], **{k: v for k, v in _sub(None, s).items()
                                        if k in ("seatsUsed", "seatsTotal", "activeStart", "willRenew", "platform")}}
            if not w["sub"]["billing"]:
                w["sub"]["billing"] = s.get("billing_period") or ""
        elif team:
            w["errors"].append(t("席位{e}，沿用上次", e=e))
        if team:
            m, e = _members(w["id"], tok)
            if m is None:
                at = w.get("membersAt") or 0
                w["errors"].append(
                    t("成员列表{e}，沿用 {at} 的数据", e=e, at=time.strftime("%m-%d %H:%M", time.localtime(at))) if at
                    else t("成员列表{e}，沿用上次的数据", e=e) if w["members"] is not None
                    else t("成员列表{e}，暂时拿不到", e=e))
                # 拿不到成员列表时，至少把本机登录过这个空间的账号补进去（比如刚加入的人），
                # 上次补的先去掉再按这次的 access 重补，人走了不会一直留着
                ms = [x for x in w["members"] or [] if not x.get("local")]
                have = {(x.get("email") or "").lower() for x in ms}
                for a in w["access"]:
                    if a["email"].lower() not in have:
                        have.add(a["email"].lower())
                        ms.append({"id": "local:" + a["email"].lower(), "email": a["email"], "name": "",
                                   "role": a["role"], "seat": "", "joined": 0, "deactivatedAt": 0,
                                   "local": True, "viaSlot": a.get("viaSlot") or ""})
                w["members"] = ms
            else:
                w["members"], w["membersAt"] = m, time.time()
            inv, e = _get(f"accounts/{w['id']}/invites?offset=0&limit=100&query=", tok, w["id"])
            if inv is not None:
                w["invites"] = [{"email": i.get("email_address") or i.get("email") or "",
                                 "role": i.get("role") or "", "created": iso(i.get("created_time"))}
                                for i in inv.get("items") or []]
        return w

    with ThreadPoolExecutor(3) as ex:
        out_ws = list(ex.map(per_ws, ws.values()))

    # 重置券按槽位拉：券跟着账号（空间）走，同一邮箱的不同空间各有各的券
    def per_slot(s):
        at, acct, err = slot_token(s)
        return s, (None if err else _get(RESET_CREDITS, at, acct)[0])

    old_sc = old.get("slotCredits") or {}
    slot_credits = {}
    with ThreadPoolExecutor(3) as ex:
        for s, cr in ex.map(per_slot, slots()):
            if cr is not None:
                slot_credits[s] = _credits(cr)
            elif s in old_sc:
                slot_credits[s] = old_sc[s]          # 这次没拿到就沿用上次
    for w in out_ws:
        w.pop("_tok", None)
        w.pop("_rank", None)
    if not people:
        log(t("同步账号目录失败（{err}），保留上次的数据", err=errors[0] if errors else t("没有账号")))
        return {**old, "errors": errors}, pay_notices(old)     # 交费提醒照旧按上次的成员生成
    data = {"at": time.time(),
            "people": sorted(people, key=lambda p: p["email"]),
            "workspaces": sorted(out_ws, key=lambda w: (w["structure"] != "workspace", (w["name"] or "").lower())),
            "slotCredits": slot_credits, "errors": errors}
    write_json(DIRECTORY, data)
    new = add_notices(directory_notices(data, time.time())) + pay_notices(data)
    partial = sum(1 for w in out_ws if w["errors"])
    log(t("同步账号目录：{people} 个邮箱、{ws} 个空间，新消息 {new} 条", people=len(people), ws=len(out_ws), new=len(new))
        + (t("，{errors} 个邮箱 / {partial} 个空间部分沿用上次数据", errors=len(errors), partial=partial)
           if errors or partial else "")
        + (t("（直连被 Cloudflare 拦，{n} 个请求改由 App 内置 WebKit 取到）", n=_web["n"]) if _web["n"] else ""))
    return data, new


def workspace_names():
    """workspace id → 官方名称（来自缓存）"""
    return {w["id"]: w["name"] for w in load_directory().get("workspaces", []) if w.get("name")}


# ---------- 成员台账：微信名、交费日 ----------
#
# meta.json = {"wechat": {邮箱小写: 微信名},
#              "pay":  {"空间id|邮箱小写": "YYYY-MM-DD"},   手动设的下次交费日（之后每月同一天）
#              "paid": {"空间id|邮箱小写": "YYYY-MM-DD"},   已交到哪一期（那一期的应交日）
#              "since": "YYYY-MM-DD"}                      开始记「已交」的那天（第一次用台账时写入）
# 只在读目录时合成进去（with_meta），不写进 directory.json，改了不用重新同步。
def load_meta():
    d = read_json(META, {})
    return {"wechat": d.get("wechat") or {}, "pay": d.get("pay") or {}, "paid": d.get("paid") or {},
            "since": d.get("since") or ""}


def pay_since():
    """开始记「已交」的那天：按加入日推算的，这天之前到期的各期当作已交（没法知道当时交没交）。
    第一次用到时记成今天并写回 meta.json，之后固定不变"""
    s = load_meta()["since"]
    try:
        return datetime.date.fromisoformat(s)
    except ValueError:
        pass
    today = datetime.date.today()
    with file_lock("meta"):
        d = read_json(META, {})
        if not d.get("since"):
            d["since"] = today.isoformat()
            write_json(META, d)
        s = d["since"]
    return datetime.date.fromisoformat(s)


def set_meta(kind, key, value):
    """kind=wechat：key 是邮箱；kind=pay：key 是「空间id|邮箱」，value 是 YYYY-MM-DD。
    value 为空表示删除这条。返回 (成功?, 错误说明)"""
    value = (value or "").strip()
    if kind == "wechat":
        key = (key or "").strip().lower()
    elif kind == "pay":
        wid, sep, mail = (key or "").partition("|")
        if not sep or not wid.strip() or not mail.strip():
            return False, t("交费日的键应为「空间id|邮箱」")
        key = f"{wid.strip()}|{mail.strip().lower()}"
        if value:
            try:
                datetime.date.fromisoformat(value)
            except ValueError:
                return False, t("日期格式应为 YYYY-MM-DD")
    else:
        return False, t("未知字段 {kind}", kind=kind)
    if not key:
        return False, t("缺少邮箱")
    with file_lock("meta"):
        d = load_meta()
        if value:
            d[kind][key] = value
        else:
            d[kind].pop(key, None)
        if kind == "pay":
            d["paid"].pop(key, None)   # 交费日换了锚点，已交记录跟着作废：新设的那天就是待交的一期
        write_json(META, d)
    log(t("成员台账 {kind} {key} → {value}", kind=kind, key=key, value=value or t("（删除）")))
    return True, ""


def add_months(d, k):
    """d 往后 k 个月；日超出当月天数就取当月最后一天
    （每次都从 d 的「日」算：1-31 → 2-28 → 3-31，不会越推越早）"""
    y, m = divmod(d.month - 1 + k, 12)
    y += d.year
    return datetime.date(y, m + 1, min(d.day, calendar.monthrange(y, m + 1)[1]))


def pay_state(manual, paid, joined, since):
    """→ (本期应交日, 已交到的那期)，都是 date；算不出来 (None, None)

    各期应交日 = 锚点 + k 个月，锚点 = 手动设的下次交费日，没有就用加入日期（本地时区）。
    「已交到」取 meta 里记的；没记过时：手动设的那天本身待交（已交到它前一个月），
    按加入日的，since（pay_since）之前到期的各期当作已交（加入当天那期本来就交过）。
    本期应交 = 已交到之后的下一期。过了日子还没标记就是逾期，不会自己顺延到下个月。
    """
    try:
        if manual:
            a = datetime.date.fromisoformat(manual)
        elif joined:
            a = datetime.date.fromtimestamp(joined)
        else:
            return None, None
        p = datetime.date.fromisoformat(paid) if paid else None
    except ValueError:
        return None, None
    if p is None:
        if manual:
            p = add_months(a, -1)
        else:
            k = 0
            while add_months(a, k + 1) < since:
                k += 1
            p = add_months(a, k)
    k = 0
    while add_months(a, k) <= p:
        k += 1
    return add_months(a, k), p


def _member(key):
    """「空间id|邮箱」→ 目录里的成员记录，找不到 None"""
    wid, _, mail = key.partition("|")
    for w in load_directory().get("workspaces", []):
        if w.get("id") == wid:
            return next((m for m in w.get("members") or [] if (m.get("email") or "").lower() == mail.lower()), None)
    return None


def mark_paid(key, undo=False):
    """标记本期已交（已交到 → 本期应交日，下次交费顺延一个月）；undo 退回上一期 → (成功?, 错误说明)"""
    wid, sep, mail = (key or "").partition("|")
    if not sep or not wid.strip() or not mail.strip():
        return False, t("键应为「空间id|邮箱」")
    key = f"{wid.strip()}|{mail.strip().lower()}"
    m = _member(key)
    if not m:
        return False, t("目录里没有这个成员，先同步一次")
    since = pay_since()
    with file_lock("meta"):
        d = load_meta()
        manual = d["pay"].get(key) or ""
        due, p = pay_state(manual, d["paid"].get(key) or "", m.get("joined"), since)
        if not due:
            return False, t("算不出交费日")
        if undo:
            a = datetime.date.fromisoformat(manual) if manual else datetime.date.fromtimestamp(m["joined"])
            k = 0
            while add_months(a, k + 1) < p:
                k += 1
            prev = add_months(a, k)
            if prev < p:
                d["paid"][key] = prev.isoformat()
            elif manual:
                d["paid"][key] = add_months(a, -1).isoformat()
            else:
                return False, t("已经是第一期了")
        else:
            d["paid"][key] = due.isoformat()
        write_json(META, d)
    log(t("成员台账 {key} 撤销已交 → 已交到 {paid}", key=key, paid=d["paid"][key]) if undo
        else t("成员台账 {key} {due} 这期已交", key=key, due=due))
    return True, ""


def with_meta(d):
    """给目录合成台账字段（返回新对象，不改 d）：
    成员加 wechat / nextPay（本地当天 0 点的 epoch，算不出为 None）/ payManual；邮箱加 wechat。
    空间所有者、我自己的账号邮箱、已停用的成员不算交费（nextPay 为 None）。"""
    meta = load_meta()
    wx, pay, paid = meta["wechat"], meta["pay"], meta["paid"]
    since = pay_since()
    mine = {((info(slot_path(s)) or {}).get("email") or "").lower() for s in slots()} - {""}
    ws = []
    for w in d.get("workspaces", []):
        if w.get("members") is None:
            ws.append(w)
            continue
        ms = []
        for m in w["members"]:
            mail = (m.get("email") or "").lower()
            key = f"{w['id']}|{mail}"
            manual = pay.get(key) or ""
            skip = m.get("role") == "account-owner" or mail in mine or m.get("deactivatedAt")
            n, p = (None, None) if skip else pay_state(manual, paid.get(key) or "", m.get("joined"), since)
            ms.append({**m, "wechat": wx.get(mail, ""), "payManual": bool(manual),
                       "nextPay": int(time.mktime(n.timetuple())) if n else None,
                       "paidThrough": int(time.mktime(p.timetuple())) if p else None,
                       "paidMarked": key in paid})
        ws.append({**w, "members": ms})
    people = [{**p, "wechat": wx.get((p.get("email") or "").lower(), "")} for p in d.get("people", [])]
    return {**d, "workspaces": ws, "people": people}


# ---------- 消息中心 ----------
def directory_notices(d, now):
    """从账号目录推出需要提醒的事：3 天内续费 / 到期、3 天内新加入的成员、即将过期的重置券…

    id 由事件本身决定（空间 + 时刻），重复同步不会重复提醒。
    """
    span = NOTICE_DAYS * 86400
    day = lambda t: time.strftime("%m-%d %H:%M", time.localtime(t))
    res = []
    for w in d.get("workspaces", []):
        name = w.get("name") or t("个人空间 · {email}", email=w["access"][0]["email"] if w.get("access") else "")
        s = w.get("sub") or {}
        if s.get("active"):
            if s.get("cancelsAt") or not s.get("willRenew"):
                ts = s.get("cancelsAt") or s.get("expiresAt")
                if ts and 0 < ts - now <= span:
                    res.append({"id": f"expire:{w['id']}:{int(ts)}", "kind": "billing", "level": "critical",
                                "title": t("{name} 将于 {day} 到期", name=name, day=day(ts)), "ws": w["id"], "at": ts,
                                "body": t("已关闭自动续费，到期后这个空间的账号将无法使用")})
            else:
                ts = s.get("renewsAt")
                if ts and 0 < ts - now <= span:
                    res.append({"id": f"renew:{w['id']}:{int(ts)}", "kind": "billing", "level": "warn",
                                "title": t("{name} 将于 {day} 自动续费", name=name, day=day(ts)), "ws": w["id"], "at": ts,
                                "body": f"{w.get('planName') or w.get('plan')} · {s.get('billing') or ''}"
                                        + (t(" · 席位 {used}/{total}", used=s["seatsUsed"], total=s["seatsTotal"])
                                           if s.get("seatsTotal") else "")})
            if s.get("delinquent"):
                res.append({"id": f"delinquent:{w['id']}", "kind": "billing", "level": "critical",
                            "title": t("{name} 扣费失败", name=name), "ws": w["id"], "at": now,
                            "body": t("订阅处于欠费状态，请尽快更新付款方式")})
        for m in w.get("members") or []:
            if m.get("joined") and 0 <= now - m["joined"] <= span and m.get("role") != "account-owner":
                res.append({"id": f"join:{w['id']}:{m['id']}", "kind": "member", "level": "info",
                            "title": t("新成员加入 {name}", name=name), "ws": w["id"], "at": m["joined"],
                            "body": t("{email}（{name}） · {day} 加入", email=m["email"], name=m["name"], day=day(m["joined"]))
                            if m.get("name") else t("{email} · {day} 加入", email=m["email"], day=day(m["joined"]))})
            if m.get("deactivatedAt") and 0 <= now - m["deactivatedAt"] <= span:
                res.append({"id": f"leave:{w['id']}:{m['id']}", "kind": "member", "level": "info",
                            "title": t("成员离开 {name}", name=name), "ws": w["id"], "at": m["deactivatedAt"],
                            "body": t("{email} · {day} 停用", email=m["email"], day=day(m["deactivatedAt"]))})
        for i in w.get("invites") or []:
            if i.get("created") and 0 <= now - i["created"] <= span:
                res.append({"id": f"invite:{w['id']}:{i['email']}", "kind": "member", "level": "info",
                            "title": t("{name} 发出了新邀请", name=name), "ws": w["id"], "at": i["created"],
                            "body": t("{email} 尚未接受", email=i["email"])})
    mail_of = {s: p["email"] for p in d.get("people", []) for s in p.get("slots") or []}
    for slot, cs in sorted((d.get("slotCredits") or {}).items()):
        for c in cs:
            ts = c.get("expiresAt") or 0
            if c.get("status") == "available" and 0 < ts - now <= span:
                res.append({"id": f"credit:{c['id']}", "kind": "quota", "level": "warn",
                            "title": t("槽 {slot}（{email}）有一张额度重置券 {day} 过期", slot=slot,
                                       email=mail_of.get(slot, ""), day=day(ts)),
                            "at": ts, "body": t("{title}，过期作废", title=c.get("title") or t("免费额度重置"))})
    return res


def pay_notices(d=None):
    """交费提醒：今天起 NOTICE_DAYS 天内（含今天）该交费的成员记进消息中心，返回新增的那些

    独立于 directory_notices：同步失败沿用旧目录时也要跑（保证每天都能提醒），
    改了交费日之后也要立刻重算。id 带上交费日期，同一期只提醒一次。
    """
    d = with_meta(load_directory() if d is None else d)
    today = datetime.date.today()
    res = []
    for w in d.get("workspaces", []):
        members = w.get("members") or []
        owner = next((m.get("email") for m in members if m.get("role") == "account-owner"), "") \
            or next((x["email"] for x in w.get("access") or [] if x.get("role") == "account-owner"), "")
        name = w.get("name") or t("个人空间 · {email}", email=w["access"][0]["email"] if w.get("access") else "")
        for m in members:
            ts = m.get("nextPay")
            if not ts:
                continue
            due = datetime.date.fromtimestamp(ts)
            days = (due - today).days
            if days > NOTICE_DAYS:
                continue
            late = days < 0                     # 过了应交日还没标记已交
            who = m.get("wechat") or m.get("email")
            joined = time.strftime("%Y-%m-%d", time.localtime(m["joined"])) if m.get("joined") else t("未知")
            res.append({"id": f"pay:{w['id']}:{(m.get('email') or '').lower()}:{due.isoformat()}" + (":late" if late else ""),
                        "kind": "pay", "level": "error" if late else "warn", "ws": w["id"], "at": ts,
                        "title": t("{who} {due} 的费用已逾期 {days} 天", who=who, due=f"{due:%m-%d}", days=-days) if late
                        else t("{who} {due} 该交费了", who=who, due=f"{due:%m-%d}"),
                        "body": t("{name} · 所有者 {owner} · {joined} 加入", name=name, owner=owner or t("未知"), joined=joined)
                                + (t("（交费日手动设置）") if m.get("payManual") else "")})
    return add_notices(res)


def load_notices():
    return read_json(NOTICES, {"items": []})


def add_notices(items):
    """新消息入库（按 id 去重），返回真正新增的那些"""
    if not items:
        return []
    now = time.time()
    with file_lock("notices"):
        d = load_notices()
        have = {n["id"] for n in d["items"]}
        new = []
        for n in items:
            if n["id"] in have:
                continue
            n = {"level": "info", "body": "", "ws": "", "slot": "", **n, "created": now, "read": False}
            d["items"].append(n)
            new.append(n)
        d["items"] = sorted(d["items"], key=lambda n: -n["created"])[:500]
        write_json(NOTICES, d)
    for n in new[:3]:
        notify(n["title"], n.get("body") or "")
    if len(new) > 3:
        notify(t("还有 {n} 条新消息", n=len(new) - 3), t("打开「ChatGPT 账号」的消息中心查看"))
    return new


def push_event(kind, title, body="", level="info", slot=""):
    """守护进程等运行时事件（切号、等待、续答失败）也记进消息中心"""
    now = time.time()
    return add_notices([{"id": f"evt:{kind}:{now:.3f}", "kind": kind, "level": level,
                         "title": title, "body": body, "at": now, "slot": slot}])


def mark_notices(ids):
    """标为已读；ids 为空表示全部"""
    with file_lock("notices"):
        d = load_notices()
        for n in d["items"]:
            if not ids or n["id"] in ids:
                n["read"] = True
        write_json(NOTICES, d)


# 装在 App 里运行时（Contents/Resources/engine.py）旁边就是 App 的可执行文件；源码目录直接跑时没有
APP_BIN = os.path.normpath(os.path.join(HERE, "..", "MacOS", "ChatGPTAccounts"))


def notify(title, text=""):
    """尽力发一条 macOS 通知，失败不影响主流程

    优先让本 App 的可执行文件发（--notify），通知上是本 App 的图标和名字；不在 App 里运行、
    App 还没拿到通知权限或发送失败时，退回 osascript（图标是「脚本编辑器」）。
    用户在系统设置里关掉了本 App 的通知（退出码 2）就不再补发。
    """
    if DEMO:
        return
    if os.access(APP_BIN, os.X_OK):
        try:
            r = subprocess.run([APP_BIN, "--notify", title, text], capture_output=True, timeout=15)
            if r.returncode in (0, 2):
                return
        except Exception:
            pass
    q = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    app = t("ChatGPT 账号")
    try:
        subprocess.run(["/usr/bin/osascript", "-e",
                        f'display notification "{q(text)}" with title "{q(app)}" subtitle "{q(title)}"'],
                       capture_output=True, timeout=10)
    except Exception:
        pass


# ---------- 自动切号开关与守护进程 ----------
def load_config():
    c = read_json(CONFIG, None)
    if c is None:
        # 旧版用 autoswitch.off 文件当暂停开关，迁移过来
        off = os.path.join(P, "autoswitch.off")
        c = {"enabled": not os.path.exists(off)}
        try:
            write_json(CONFIG, c)
            if os.path.exists(off):
                os.remove(off)
        except Exception:
            pass
    for k, v in CONFIG_DEFAULTS.items():
        c.setdefault(k, list(v) if isinstance(v, list) else v)
    return c


# enabled 总开关；prompt 续答用语；stall_nudge 停滞提醒；
# order 切号顺序：alpha = 按字母往后找，most = 优先 5 小时剩余最多的，soon = 优先 5 小时窗口最早重置的；
# auto_start 自动开始计时：5 小时窗口没开始的账号，由后台服务挨个发一句极短的请求起算；
# auto_continue 回合正常结束后自动发续答用语，continue_max 同一个对话连续自动继续的上限（用户发消息后重新计数）；
# quiet_switch 后台切号：自动切号、续答时不把 ChatGPT 叫到前台，也不让它跳到被续答的对话；
# skip 不参与轮换的槽位：自动切号挑下一个时跳过它们（手动切过去照常能用）；
# lang 界面语言 zh / en（App 启动时按它的界面语言写；空 = 还没写过，按中文）
PROMPT_DEFAULT = {"zh": "继续", "en": "Continue"}       # i18n-ignore  默认续答用语，按界面语言
CONFIG_DEFAULTS = {"enabled": True, "prompt": "继续", "stall_nudge": True, "order": "alpha", "auto_start": False,  # i18n-ignore
                   "auto_continue": False, "continue_max": 5, "quiet_switch": True, "skip": [], "lang": ""}


def set_config(key, value):
    if key not in CONFIG_DEFAULTS or type(value) is not type(CONFIG_DEFAULTS[key]):
        raise ValueError(t("不支持的设置：{key}={value!r}", key=key, value=value))
    if key == "prompt" and not value.strip():
        raise ValueError(t("续答用语不能为空"))
    if key == "order" and value not in ("alpha", "most", "soon"):
        raise ValueError(t("切号顺序只能是 alpha、most 或 soon"))
    if key == "continue_max" and not 1 <= value <= 50:
        raise ValueError(t("自动继续次数上限要在 1 到 50 之间"))
    if key == "lang" and value not in ("", "zh", "en"):
        raise ValueError(t("lang 只能是 zh 或 en"))
    if key == "skip":
        if not all(type(s) is str for s in value):
            raise ValueError(t("skip 要是槽位名列表"))
        value = sorted(set(value))
    with file_lock("config"):
        c = load_config()
        if key == "lang" and value != c.get("lang"):
            # 续答用语还是另一种语言的默认值，就跟着换成这种语言的（自己改过的不动）
            want, other = PROMPT_DEFAULT.get(value or "zh"), PROMPT_DEFAULT.get("zh" if value == "en" else "en")
            if c.get("prompt") == other:
                c["prompt"] = want
        c[key] = value
        write_json(CONFIG, c)
    log(t("设置 {key} = {value}", key=key, value=value))
    return c


def daemon_plist():
    script = os.path.join(HERE, "autoswitch.py")
    err = os.path.join(P, "autoswitch.err.log")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{DAEMON_LABEL}</string>
<key>ProgramArguments</key><array>
  <string>/usr/bin/python3</string>
  <string>{script}</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>30</integer>
<key>StandardOutPath</key><string>/dev/null</string>
<key>StandardErrorPath</key><string>{err}</string>
</dict></plist>
"""


def ensure_daemon(restart=False):
    """确保守护进程装好并在跑：plist 内容变了就重装，没加载就加载"""
    target = f"gui/{os.getuid()}/{DAEMON_LABEL}"

    def loaded():
        return subprocess.run(["/bin/launchctl", "print", target],
                              capture_output=True).returncode == 0

    want = daemon_plist()
    have = open(DAEMON_PLIST).read() if os.path.exists(DAEMON_PLIST) else ""
    if have != want:
        os.makedirs(os.path.dirname(DAEMON_PLIST), exist_ok=True)
        with open(DAEMON_PLIST, "w") as f:
            f.write(want)
    if have != want or not loaded():
        # bootout 是异步的：旧进程还没退干净就 bootstrap 会报 5: Input/output error
        subprocess.run(["/bin/launchctl", "bootout", target], capture_output=True)
        for _ in range(30):
            if not loaded():
                break
            time.sleep(0.5)
        r = subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", DAEMON_PLIST],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return False, r.stderr.strip() or t("launchctl 返回 {code}", code=r.returncode)
        log(t("守护进程已（重新）安装"))
    elif restart:
        subprocess.run(["/bin/launchctl", "kickstart", "-k", target], capture_output=True)
    return True, ""


def auto_status():
    """开关 + 守护进程汇报的状态，给 UI 顶部那一栏用"""
    c = load_config()
    st = read_json(STATE, {})
    s = st.get("status") or {}
    alive = DEMO or time.time() - (st.get("heartbeat") or 0) < 30
    return {"enabled": c["enabled"], "alive": alive,
            "phase": s.get("phase", ""), "text": s.get("text", ""),
            "waitUntil": (st.get("wait") or {}).get("until") or 0,
            "queue": len(st.get("queue") or [])}


# ---------- 给原生 UI 用的 JSON 接口 ----------
def api_list():
    cur = info(AUTH)
    lu, nm, q, wn = lastused(), names(), load_quota(), workspace_names()
    wx = load_meta()["wechat"]
    now = time.time()
    rows = []
    for s in slots():
        i = info(slot_path(s)) or {}
        e = q.get(s) or {}
        av = available_at(e, now)
        rows.append({
            "slot":       s,
            "name":       nm.get(s, ""),
            "workspace":  wn.get(i.get("acct") or "", ""),
            "email":      i.get("email") or "",
            "wechat":     wx.get((i.get("email") or "").lower(), ""),
            "acct":       i.get("acct") or "",
            "plan":       i.get("plan") or "",
            "current":    same_account(i, cur),
            "days":       i.get("days", -1),
            "lastExit":   lu.get(s, ""),
            "ok":         bool(i.get("acct")),
            "needsLogin": needs_login(slot_path(s)),
            "usage": {
                "at":         e.get("at") or 0,
                "primary":    e.get("primary"),
                "secondary":  e.get("secondary"),
                "error":      e.get("error") or "",
                "availableAt": av if av is not None else -1,
                "blockReason": e.get("block_reason") or ""
                               if (e.get("block_until") or 0) > now else "",
                "limitType":  e.get("limit_type") or "",
                "resets":     e.get("resets") or 0,
                "startedAt":  e.get("started_at") or 0,
            },
        })
    unread = sum(1 for n in load_notices()["items"] if not n.get("read"))
    out({"slots": rows, "running": bool(running()), "auto": auto_status(),
         "config": load_config(), "unread": unread})


def api_directory(refresh):
    """空间 / 订阅 / 成员目录；refresh 或没有缓存时联网同步"""
    d = load_directory()
    if refresh or not d.get("at"):
        d, _ = sync_directory()
    out({"ok": True, **with_meta(d), "hidden": read_json(HIDDEN_TEAMS, [])})


def api_hide_team(wid, hide):
    """团队页「从列表移除」/ 恢复：只改本机的显示，不动 ChatGPT 那边的空间"""
    ids = [i for i in read_json(HIDDEN_TEAMS, []) if i != wid] + ([wid] if hide else [])
    write_json(HIDDEN_TEAMS, ids)
    out({"ok": True, "hidden": ids})


def api_phrases():
    """中英对照表（engine.py 和 autoswitch.py 里 t() 的全部句子）：App 用它把以前按另一种语言写下的消息、日志换成当前语言"""
    table = {**EN_OLD, **EN}
    try:
        # autoswitch.py 的句子是导入时 update 进它自己那份 engine 的 EN 表的
        spec = importlib.util.spec_from_file_location("autoswitch_phrases", os.path.join(HERE, "autoswitch.py"))
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        table.update(m.eng.EN)
    except Exception as e:
        log(t("读取 autoswitch.py 的译文失败：{err}", err=type(e).__name__))
    out({"ok": True, "pairs": table})


def api_notices():
    d = load_notices()
    out({"ok": True, "items": d["items"], "unread": sum(1 for n in d["items"] if not n.get("read"))})


def api_refresh_usage(which):
    for s in which or slots():
        fetch_usage(s)
    out({"ok": True})


def api_resume(threads):
    """请守护进程在这些对话里发一句「继续」（它下一轮就会处理）"""
    with file_lock("request"):
        req = read_json(REQUEST, []) + threads
        write_json(REQUEST, req)
    out({"ok": True, "queued": threads})


def api_continue(threads):
    """会话页的「继续」：请守护进程马上在这些对话里后台发一句「继续」"""
    with file_lock("request"):
        req = read_json(REQUEST, []) + [{"thread": t, "bg": True} for t in threads]
        write_json(REQUEST, req)
    out({"ok": True, "queued": threads})


def api_pause(threads):
    """会话页的「暂停」：请守护进程停下这些对话正在跑的这一轮，并移出续答队列"""
    if not threads:
        return out({"ok": False, "err": t("没有要暂停的对话")}, False)
    with file_lock("request"):
        req = read_json(REQUEST, []) + [{"thread": t, "pause": True} for t in threads]
        write_json(REQUEST, req)
    out({"ok": True, "queued": threads})


def api_set_thread(arg):
    """会话页改模型 / 推理强度 / 速度：交给守护进程经总线改（下一轮生效）"""
    try:
        d = json.loads(arg)
        threads, settings = list(d["threads"]), {k: v for k, v in d["settings"].items() if k in ("model", "effort", "tier") and v}
    except (ValueError, KeyError, TypeError, AttributeError):
        return out({"ok": False, "err": t("参数格式不对")}, False)
    if not threads or not settings:
        return out({"ok": False, "err": t("没有要改的对话或设置")}, False)
    with file_lock("request"):
        req = read_json(REQUEST, []) + [{"thread": t, "settings": settings} for t in threads]
        write_json(REQUEST, req)
    out({"ok": True, "queued": threads})


def api_switch(slot, force):
    ok, r = switch(slot, force)
    out({"ok": ok, **r}, ok)


def api_auto_begin(slot):
    """添加前置：存回当前凭证 → 退出 ChatGPT → codex logout → 用新槽位自己的
    profile 开一个干净窗口，让用户在里面登录（网页会话和 auth.json 才成对）"""
    cur = info(AUTH)
    if not quit_app():
        out({"ok": False, "err": t("ChatGPT 没能退出，请手动 Cmd+Q 后重试")}, False)
    stash_current()
    backup_auth()
    if cur:
        mark_exit(find_slot(cur))
    try:
        subprocess.run([CODEX, "logout"], capture_output=True, text=True, timeout=30)
    except Exception:
        pass
    launch(slot)
    log(t("添加：已退出并登出，用槽 {slot} 的 profile 开窗等待登录", slot=slot))
    out({"ok": True, "slot": slot})


def api_next_slot():
    """预分配下一个空槽位字母，UI 在登录前就要确定 profile"""
    slot = next((c for c in SLOTPOOL if c not in set(slots())), "")
    out({"ok": bool(slot), "slot": slot, "err": "" if slot else t("槽位已满")})


def api_relaunch(slot):
    """添加完成：登录用的 ChatGPT 就是新槽位的，一般还开着，不动它；被关掉了才在后台拉起"""
    if running():
        log(t("添加完成（槽 {slot}），ChatGPT 已在运行", slot=slot))
    else:
        launch(slot, background=True)
        log(t("添加完成，后台拉起 ChatGPT（槽 {slot}）", slot=slot))
    out({"ok": True})


def api_current():
    """当前登录状态，供 UI 轮询登录是否完成"""
    cur = info(AUTH) or {}
    out({"acct": cur.get("acct") or "", "user": cur.get("user") or "", "email": cur.get("email") or "",
         "plan": cur.get("plan") or "", "known": bool(find_slot(cur))})


def api_capture():
    """把当前登录的凭证收进一个新槽位（添加账号的最后一步）"""
    new = info(AUTH)
    if not new or not new["acct"]:
        out({"ok": False, "err": t("没读到凭证，可能还没登录成功")}, False)
    dup = find_slot(new)
    if dup:
        out({"ok": False, "err": t("{email} 的这个 workspace 已在槽位 {dup}", email=new["email"], dup=dup),
             "dup": dup, "email": new["email"]}, False)
    slot = next((c for c in SLOTPOOL if c not in set(slots())), None)
    if not slot:
        out({"ok": False, "err": t("槽位已满")}, False)
    shutil.copy2(AUTH, slot_path(slot))
    log(t("添加 {email} / {acct} → 槽 {slot}", email=new["email"], acct=new["acct"][:8], slot=slot))
    fetch_usage(slot)
    out({"ok": True, "slot": slot, "email": new["email"], "plan": new["plan"] or ""})


def api_reset_credit(slot, credit_id):
    ok, err, code, usage = reset_credit(slot, credit_id)
    out({"ok": ok, "err": err, "code": code, "usage": usage}, ok)


def api_start_window(slot):
    ok, err, usage = start_window(slot)
    out({"ok": ok, "err": err, "usage": usage}, ok)


def api_mark_paid(key, undo):
    ok, err = mark_paid(key, undo)
    if ok:
        pay_notices()
    out({"ok": ok, "err": err}, ok)


def api_meta_set(kind, key, value):
    ok, err = set_meta(kind, key, value)
    if ok and kind == "pay":
        pay_notices()                  # 改了交费日立刻重算提醒
    out({"ok": ok, "err": err}, ok)


def api_rename(slot, name):
    d = names()
    if name.strip():
        d[slot] = name.strip()
    else:
        d.pop(slot, None)
    save_names(d)
    log(t("重命名槽 {slot} → {name}", slot=slot, name=name))
    out({"ok": True})


def api_delete(slot):
    """删除槽位（只删本机凭证），禁止删当前正在用的那个"""
    cur, i = info(AUTH), info(slot_path(slot))
    if same_account(cur, i):
        out({"ok": False, "err": t("不能删除当前正在使用的账号")}, False)
    if os.path.exists(slot_path(slot)):
        os.remove(slot_path(slot))
    d = names(); d.pop(slot, None); save_names(d)
    if slot in load_config()["skip"]:          # 别让以后同名的新槽位继承「不参与轮换」
        set_config("skip", [s for s in load_config()["skip"] if s != slot])
    with file_lock("quota"):
        q = load_quota(); q.pop(slot, None); write_json(QUOTA, q)
    log(t("删除槽 {slot} ({email})", slot=slot, email=(i or {}).get("email")))
    out({"ok": True})


# 演示模式下这些命令什么都不做，直接报成功：它们会联网、动 ChatGPT 进程或装后台服务
DEMO_NOOP = {"--slot", "--refresh-usage", "--ensure-daemon", "--capture", "--auto-begin", "--relaunch",
             "--reset-credit", "--start-window", "--resume", "--continue", "--set-thread", "--pause"}


def main():
    os.makedirs(P, exist_ok=True)
    a = sys.argv[1:]
    cmd = a[0] if a else ""
    if DEMO and cmd in DEMO_NOOP:
        return out({"ok": True, "err": ""})
    if DEMO and cmd == "--directory-json":
        return api_directory(False)
    if cmd == "--list-json":      return api_list()
    if cmd == "--slot":           return api_switch(a[1], "--force" in a)
    if cmd == "--refresh-usage":  return api_refresh_usage(a[1:])
    if cmd == "--set-auto":       return out({"ok": True, **set_config("enabled", a[1] == "on")})
    if cmd == "--set-config":     return out({"ok": True, **set_config(a[1], json.loads(a[2]))})
    if cmd == "--resume":         return api_resume(a[1:])
    if cmd == "--continue":       return api_continue(a[1:])
    if cmd == "--set-thread":     return api_set_thread(a[1] if len(a) > 1 else "")
    if cmd == "--pause":          return api_pause(a[1:])
    if cmd == "--directory-json": return api_directory("--refresh" in a)
    if cmd == "--hide-team":      return api_hide_team(a[1], True)
    if cmd == "--unhide-team":    return api_hide_team(a[1], False)
    if cmd == "--notices-json":   return api_notices()
    if cmd == "--phrases-json":   return api_phrases()
    if cmd == "--notice-read":    mark_notices(a[1:]); return out({"ok": True})
    if cmd == "--ensure-daemon":
        ok, err = ensure_daemon(restart="--restart" in a)
        return out({"ok": ok, "err": err}, ok)
    if cmd == "--capture":        return api_capture()
    if cmd == "--current-json":   return api_current()
    if cmd == "--auto-begin":     return api_auto_begin(a[1])
    if cmd == "--next-slot":      return api_next_slot()
    if cmd == "--relaunch":       return api_relaunch(a[1])
    if cmd == "--rename":         return api_rename(a[1], a[2] if len(a) > 2 else "")
    if cmd == "--delete":         return api_delete(a[1])
    if cmd == "--reset-credit":   return api_reset_credit(a[1], a[2] if len(a) > 2 else "")
    if cmd == "--start-window":   return api_start_window(a[1])
    if cmd == "--start-candidates": return out({"ok": True, "slots": start_candidates(time.time())})
    if cmd == "--meta-set":       return api_meta_set(a[1], a[2], a[3] if len(a) > 3 else "")
    if cmd == "--mark-paid":      return api_mark_paid(a[1], "--undo" in a)
    out({"ok": False, "err": t("未知命令：{cmd}", cmd=" ".join(a) or t("（空）"))}, False)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        log(f"ERROR {type(e).__name__}: {e}")
        out({"ok": False, "err": f"{type(e).__name__}: {e}"}, False)
