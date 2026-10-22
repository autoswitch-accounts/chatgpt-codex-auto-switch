#!/usr/bin/env python3
"""生成一份演示用的假数据（截图 / 试用界面用），写进「假家目录」DEST：

  DEST/Library/Application Support/codex-profiles/   槽位、额度、目录、台账、消息、日志
  DEST/.codex/                                       当前凭证、对话 rollout、对话名称

全部是虚构的：邮箱都在 example.com / .net / .org 这几个保留域名下，token 是不带签名的假 JWT，
时间都相对「现在」生成，所以什么时候跑都是一份新鲜的数据。由 scripts/demo.sh 调用。
"""
import os, sys, json, time, base64, uuid, datetime, importlib.util

if len(sys.argv) != 2:
    sys.exit("用法：demo_data.py 假家目录")
DEST = os.path.abspath(sys.argv[1])
if DEST == os.path.abspath(os.path.expanduser("~")):
    sys.exit("不能写进真实的家目录")

# engine 的路径常量在导入时按 HOME 算，先指过去；DEMO=1 让它不弹通知
os.environ["HOME"] = DEST
os.environ["CGA_DEMO"] = "1"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("engine", os.path.join(ROOT, "engine.py"))
eng = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(eng)
assert eng.P.startswith(DEST)

NOW = time.time()
H, D = 3600, 86400
TODAY = datetime.date.today()


def day(n):
    """今天往前 n 天的本地时间（中午），epoch"""
    d = TODAY - datetime.timedelta(days=n)
    return time.mktime(datetime.datetime(d.year, d.month, d.day, 12).timetuple())


def b64(o):
    return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")


def jwt(claims):
    return b64({"alg": "none", "typ": "JWT"}) + "." + b64(claims) + ".demo"


def ws_id(n):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"demo-workspace-{n}"))


# ---------- 我的账号（槽位） ----------
TEAMS = {"polaris": ws_id(1), "acme": ws_id(2), "bluelab": ws_id(3), "night": ws_id(4)}
SLOTS = [
    # 槽, 邮箱, 空间, 套餐, 订阅剩余天数
    ("A", "lin.studio@example.com", TEAMS["polaris"], "team", 23),
    ("B", "lin.studio@example.com", ws_id(11), "plus", 12),
    ("C", "maya.design@example.com", TEAMS["acme"], "team", 17),
    ("D", "kevin.dev@example.com", TEAMS["bluelab"], "team", 28),
    ("E", "ops.hub@example.com", ws_id(12), "pro", 9),
    ("F", "night.owl@example.com", TEAMS["night"], "team", 17),
    ("G", "test.bench@example.com", ws_id(13), "plus", 4),
    ("H", "old.account@example.com", ws_id(14), "plus", -1),
]
CURRENT = "C"
NAMES = {"A": "主力", "C": "设计组", "E": "Pro 备用"}

# 额度：(5 小时已用 %, 5 小时还剩多久重置, 本周已用 %, 本周还剩多久重置)
QUOTA = {
    "A": (100, 1.6 * H, 64, 3.2 * D),
    "B": (23, 3.1 * H, 41, 5.5 * D),
    "C": (58, 2.4 * H, 37, 4.1 * D),
    "D": (0, 5 * H, 6, 6.8 * D),          # 还没开始计时
    "E": (81, 0.7 * H, 92, 1.3 * D),
    "F": (34, 4.2 * H, 100, 2.6 * D),     # 本周用满
    "G": (12, 4.6 * H, 18, 6.1 * D),
    "H": (0, 0, 0, 0),
}

prof = eng.P
os.makedirs(prof, exist_ok=True)
os.makedirs(os.path.join(DEST, ".codex"), exist_ok=True)

for s, mail, acct, plan, days in SLOTS:
    exp = NOW - 2 * D if s == "H" else NOW + 10 * D
    until = datetime.datetime.fromtimestamp(NOW + days * D, datetime.timezone.utc).isoformat() if days > 0 else ""
    auth = {"https://api.openai.com/auth": {"chatgpt_account_id": acct, "chatgpt_plan_type": plan,
                                            "chatgpt_subscription_active_until": until}}
    data = {"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
            "tokens": {"id_token": jwt({"email": mail, "exp": exp, **auth}),
                       "access_token": jwt({"exp": exp}),
                       "refresh_token": "" if s == "H" else "demo-refresh-token",
                       "account_id": acct},
            "last_refresh": time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime(NOW - 3 * H))}
    eng.write_json(eng.slot_path(s), data)
    if s == CURRENT:
        eng.write_json(eng.AUTH, data)

eng.write_json(eng.NAMES, NAMES)
eng.write_json(eng.LASTUSED, {s: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(NOW - (i + 1) * 2.7 * H))
                              for i, (s, *_ ) in enumerate(SLOTS) if s != CURRENT})
q = {}
for s, (p_used, p_left, w_used, w_left) in QUOTA.items():
    if s == "H":
        q[s] = {"at": NOW - 2 * D, "src": "api", "primary": None, "secondary": None,
                "reached": False, "error": "凭证过期，切到这个账号一次即可刷新", "error_at": NOW - 2 * D}
        continue
    q[s] = {"at": NOW - 90, "src": "api",
            "primary": {"used": float(p_used), "reset_at": int(NOW + p_left), "window": 5 * H},
            "secondary": {"used": float(w_used), "reset_at": int(NOW + w_left), "window": 7 * D},
            "reached": p_used >= 100 or w_used >= 100, "error": "", "error_at": 0,
            "limit_type": "rate_limit_reached" if p_used >= 100 or w_used >= 100 else "",
            "resets": {"A": 2, "C": 1}.get(s, 0)}
eng.write_json(eng.QUOTA, q)
eng.write_json(eng.CONFIG, {"enabled": True, "prompt": "继续", "stall_nudge": True, "order": "soon",
                            "auto_start": True, "auto_continue": True, "continue_max": 5})
eng.write_json(eng.STATE, {"queue": [], "wait": None, "last_switch_at": NOW - 42 * 60, "nudged": {},
                           "switching": None, "status": {"phase": "idle", "text": ""}, "heartbeat": NOW})

# ---------- 空间 / 订阅 / 成员 ----------
def sub(active=True, renew_in=20, billing="monthly", seats=(0, 0), plan="team", cancel_in=0):
    return {"active": active, "plan": plan, "renewsAt": NOW + renew_in * D if active and not cancel_in else 0,
            "expiresAt": NOW + (cancel_in or renew_in) * D if active else 0,
            "cancelsAt": NOW + cancel_in * D if cancel_in else 0, "willRenew": not cancel_in,
            "billing": billing, "currency": "USD", "activeStart": NOW - 120 * D,
            "seatsUsed": seats[0], "seatsTotal": seats[1], "discount": "", "delinquent": False,
            "graceEnd": 0, "platform": "chatgpt_web", "trial": False}


def member(mail, name, joined_days_ago, role="standard-user", left_days_ago=0):
    return {"id": "user-" + uuid.uuid5(uuid.NAMESPACE_URL, mail).hex[:20], "email": mail, "name": name,
            "role": role, "seat": "default", "joined": day(joined_days_ago),
            "deactivatedAt": day(left_days_ago) if left_days_ago else 0}


workspaces = [
    {"id": TEAMS["polaris"], "name": "北极星工作室", "structure": "workspace", "plan": "team",
     "planName": "Business", "deactivated": False, "created": NOW - 200 * D, "slots": ["A"],
     "access": [{"email": "lin.studio@example.com", "role": "account-owner", "viaSlot": "A"}],
     "sub": sub(renew_in=2, seats=(7, 10)),
     "members": [member("lin.studio@example.com", "Lin", 200, "account-owner"),
                 member("chen.yu@example.net", "Chen Yu", 63),
                 member("sophie.w@example.net", "Sophie", 58),
                 member("jamie.k@example.net", "Jamie", 85),
                 member("leo.zhang@example.net", "Leo", 1),
                 member("hana.s@example.net", "Hana", 110),
                 member("ruby.h@example.net", "Ruby", 150, left_days_ago=20)],
     "invites": [{"email": "max.t@example.net", "role": "standard-user", "created": NOW - 5 * H}], "errors": []},
    {"id": TEAMS["acme"], "name": "Acme Design", "structure": "workspace", "plan": "team",
     "planName": "Business", "deactivated": False, "created": NOW - 160 * D, "slots": ["C"],
     "access": [{"email": "maya.design@example.com", "role": "account-owner", "viaSlot": "C"}],
     "sub": sub(renew_in=17, billing="yearly", seats=(5, 8)),
     "members": [member("maya.design@example.com", "Maya", 160, "account-owner"),
                 member("nora.l@example.org", "Nora", 133),
                 member("tom.g@example.org", "Tom", 29),
                 member("ivy.q@example.org", "Ivy", 61),
                 member("night.owl@example.com", "Owl", 90)],
     "invites": [], "errors": []},
    {"id": TEAMS["bluelab"], "name": "Blue Lab", "structure": "workspace", "plan": "team",
     "planName": "Business", "deactivated": False, "created": NOW - 40 * D, "slots": ["D"],
     "access": [{"email": "kevin.dev@example.com", "role": "account-owner", "viaSlot": "D"}],
     "sub": sub(renew_in=28, seats=(3, 5), cancel_in=28),
     "members": [member("kevin.dev@example.com", "Kevin", 40, "account-owner"),
                 member("alice.m@example.org", "Alice", 20),
                 member("ben.r@example.org", "Ben", 33)],
     "invites": [], "errors": []},
]
for s, mail, acct, plan, days in SLOTS:
    if plan != "team":
        workspaces.append({"id": acct, "name": "", "structure": "personal", "plan": plan, "planName": "",
                           "deactivated": False, "created": NOW - 300 * D, "slots": [s],
                           "access": [{"email": mail, "role": "account-owner", "viaSlot": s}],
                           "sub": sub(active=days > 0, renew_in=max(days, 1), plan=plan),
                           "members": None, "invites": [], "errors": []})
# F 只是别人团队里的普通成员：看不到成员列表
workspaces.append({"id": TEAMS["night"], "name": "夜班小组", "structure": "workspace", "plan": "team",
                   "planName": "Business", "deactivated": False, "created": NOW - 70 * D, "slots": ["F"],
                   "access": [{"email": "night.owl@example.com", "role": "standard-user", "viaSlot": "F"}],
                   "sub": sub(renew_in=11, seats=(0, 0)), "members": None, "invites": [], "errors": []})


def credit(n, expires_in, status="available"):
    return {"id": f"demo-credit-{n}", "title": "免费额度重置", "status": status,
            "expiresAt": NOW + expires_in * D, "grantedAt": NOW - 10 * D}


people = []
for mail in sorted({m for _, m, *_ in SLOTS}):
    people.append({"email": mail, "name": mail.split("@")[0].split(".")[0].title(),
                   "userId": "user-" + uuid.uuid5(uuid.NAMESPACE_URL, "p" + mail).hex[:20],
                   "created": NOW - 400 * D, "mfa": True, "country": "US",
                   "slots": [s for s, m, *_ in SLOTS if m == mail],
                   "resetCredits": {"lin.studio@example.com": [credit(1, 2), credit(2, 20)],
                                    "maya.design@example.com": [credit(3, 12), credit(4, -3, "redeemed")]
                                    }.get(mail, [])})
directory = {"at": NOW - 4 * 60, "people": people, "workspaces": workspaces, "errors": []}
eng.write_json(eng.DIRECTORY, directory)

# ---------- 成员台账：微信名、交费 ----------
wechat = {"chen.yu@example.net": "陈宇", "sophie.w@example.net": "Sophie", "jamie.k@example.net": "阿杰",
          "leo.zhang@example.net": "Leo 张", "hana.s@example.net": "花子", "nora.l@example.org": "Nora",
          "tom.g@example.org": "汤姆", "ivy.q@example.org": "Ivy", "alice.m@example.org": "爱丽丝",
          "ben.r@example.org": "小本", "lin.studio@example.com": "林"}
since = TODAY
paid = {}


def key(w, mail):
    return f"{TEAMS[w]}|{mail}"


def due_of(w, mail, paid_val=""):
    m = next(x for ws in workspaces if ws["id"] == TEAMS[w] for x in ws["members"] if x["email"] == mail)
    return eng.pay_state("", paid_val, m["joined"], since)


# 陈宇：上一期没交 → 逾期；阿杰、Nora：本期已交（显示 ✓ 已交）
due, p = due_of("polaris", "chen.yu@example.net")
paid[key("polaris", "chen.yu@example.net")] = eng.add_months(p, -1).isoformat()
for w, mail in (("polaris", "jamie.k@example.net"), ("acme", "nora.l@example.org")):
    due, p = due_of(w, mail)
    paid[key(w, mail)] = due.isoformat()
eng.write_json(eng.META, {"wechat": wechat, "pay": {}, "paid": paid, "since": since.isoformat()})

# ---------- 切号历史 / 消息 ----------
hist = [{"at": NOW - 9 * H, "slot": "E", "email": "ops.hub@example.com"},
        {"at": NOW - 5.5 * H, "slot": "A", "email": "lin.studio@example.com"},
        {"at": NOW - 42 * 60, "slot": "C", "email": "maya.design@example.com"}]
eng.write_json(eng.HISTORY, hist)

notices = [
    {"id": "evt:switch:1", "kind": "switch", "level": "info", "at": NOW - 42 * 60,
     "title": "lin.studio@example.com 的 5 小时额度用完，已切到 maya.design@example.com",
     "body": "槽 A → 槽 C · 自动切号", "slot": "C"},
    {"id": "evt:session:1", "kind": "session", "level": "info", "at": NOW - 40 * 60,
     "title": "已在 2 个对话里发送「继续」", "body": "落地页改版：首屏动效、API 网关限流重构", "slot": "C"},
    {"id": "evt:quota:1", "kind": "quota", "level": "warn", "at": NOW - 3 * H,
     "title": "night.owl@example.com 本周额度已用完", "body": "槽 F · 预计 " +
     time.strftime("%m-%d %H:%M", time.localtime(NOW + 2.6 * D)) + " 恢复", "slot": "F"},
]
eng.add_notices(notices)
eng.add_notices(eng.directory_notices(directory, NOW))
eng.pay_notices()
nd = eng.load_notices()
for n in nd["items"]:                       # 留几条未读，其余当作看过了
    n["read"] = n["kind"] not in ("pay", "billing")
    if n["id"].startswith("evt:"):
        n["created"] = n["at"]
nd["items"].sort(key=lambda n: -n["created"])
eng.write_json(eng.NOTICES, nd)

# ---------- 日志 ----------
def stamp(t):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))


manager = [
    (NOW - 9 * H, "切换 night.owl@example.com → ops.hub@example.com (槽 E / demo0005)"),
    (NOW - 5.5 * H, "槽 A 凭证刷新：仍有效（剩 312 分钟），跳过"),
    (NOW - 5.5 * H, "切换 ops.hub@example.com → lin.studio@example.com (槽 A / demo0001)"),
    (NOW - 3 * H, "同步账号目录：6 个邮箱、7 个空间，新消息 2 条"),
    (NOW - 42 * 60, "槽 C 凭证刷新：仍有效（剩 540 分钟），跳过"),
    (NOW - 42 * 60, "切换 lin.studio@example.com → maya.design@example.com (槽 C / demo0002)"),
    (NOW - 30 * 60, "同步账号目录：6 个邮箱、7 个空间，新消息 0 条"),
    (NOW - 10 * 60, "成员台账 pay 已交 jamie.k@example.net"),
]
auto = [
    (NOW - 44 * 60, "落地页改版：首屏动效 撞限（额度已用满），当前槽 A"),
    (NOW - 44 * 60, "联网确认：槽 A 5 小时已用 100%，切到下一个可用账号"),
    (NOW - 43 * 60, "候选：C 5h 剩 100%（剩余最多优先）"),
    (NOW - 42 * 60, "已切到槽 C，等待 ChatGPT 就绪"),
    (NOW - 41 * 60, "总线就绪，续答队列 2 个对话"),
    (NOW - 40 * 60, "已在「落地页改版：首屏动效」发送「继续」"),
    (NOW - 40 * 60, "已在「API 网关限流重构」发送「继续」"),
    (NOW - 12 * 60, "额度刷新：8 个账号，可用 5 个"),
    (NOW - 2 * 60, "额度刷新：当前槽 C 5 小时已用 58%"),
]
with open(eng.LOG, "w", encoding="utf-8") as f:
    f.writelines(f"{stamp(t)}  {m}\n" for t, m in manager)
with open(os.path.join(prof, "autoswitch.log"), "w", encoding="utf-8") as f:
    f.writelines(f"{stamp(t)}  {m}\n" for t, m in auto)

# ---------- Codex 对话（rollout）----------
codex = os.path.join(DEST, ".codex")
sess_dir = os.path.join(codex, "sessions", *TODAY.strftime("%Y %m %d").split())
os.makedirs(sess_dir, exist_ok=True)


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def rollout(title, project, last, events, parent=None, tid=None):
    tid = tid or str(uuid.uuid4())
    meta = {"id": tid, "cwd": f"/Users/demo/Projects/{project}"}
    if parent:
        meta["parent_thread_id"] = parent
    lines = [{"timestamp": iso(last - 600), "type": "session_meta", "payload": meta}]
    for dt, typ, extra in events:
        lines.append({"timestamp": iso(last - dt), "type": "event_msg", "payload": {"type": typ, **extra}})
    path = os.path.join(sess_dir, f"rollout-{time.strftime('%Y-%m-%dT%H-%M-%S', time.localtime(last - 600))}-{tid}.jsonl")
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(json.dumps(o, ensure_ascii=False, separators=(",", ":")) + "\n" for o in lines)
    os.utime(path, (last, last))
    if title:
        titles.append({"id": tid, "thread_name": title})
    return tid


titles = []
limit_err = {"error": {"codex_error_info": "usage_limit_exceeded",
                       "message": "You've hit your usage limit. Try again later."}}
main = rollout("落地页改版：首屏动效", "landing-page", NOW - 50,
               [(400, "task_complete", {}), (300, "task_started", {"turn_id": "t2"})])
rollout("", "landing-page", NOW - 80, [(200, "task_started", {"turn_id": "s1"})], parent=main)
rollout("", "landing-page", NOW - 400, [(200, "task_started", {"turn_id": "s2"}), (100, "task_complete", {})], parent=main)
rollout("API 网关限流重构", "api-gateway", NOW - 6 * 60,
        [(900, "task_started", {"turn_id": "t1"}), (0, "task_complete", {})])
rollout("修复 iOS 推送证书过期", "mobile-app", NOW - 47 * 60,
        [(300, "task_started", {"turn_id": "t1"}), (0, "task_complete", limit_err)])
rollout("周报数据看板", "analytics", NOW - 3.2 * H,
        [(1200, "task_started", {"turn_id": "t1"}), (0, "task_complete", {})])
rollout("数据库迁移脚本", "backend", NOW - 6.5 * H,
        [(500, "task_started", {"turn_id": "t1"}), (0, "turn_aborted", {})])
rollout("README 中英文对照", "docs", NOW - 20 * H,
        [(700, "task_started", {"turn_id": "t1"}), (0, "task_complete", {})])
with open(os.path.join(codex, "session_index.jsonl"), "w", encoding="utf-8") as f:
    f.writelines(json.dumps(t, ensure_ascii=False) + "\n" for t in titles)

print(DEST)
