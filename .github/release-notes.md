**下载下面的 `ChatGPT-Accounts-x.y.zip`，解压后把「ChatGPT 账号」拖进「应用程序」。** 需要 macOS 14+、Apple 芯片。

安装包没有做苹果公证：第一次打开时到「系统设置 → 隐私与安全性」点「仍要打开」，或在终端执行
`xattr -dr com.apple.quarantine "/Applications/ChatGPT 账号.app"`。

### 本版更新
- 后台切号，不打扰：自动切号和续答时 ChatGPT 不再抢到最前面、也不跳到对话（设置里可关）
- 账号可设「不参与自动轮换」，账号表按是否参与轮换分组
- 状态列：额度用满的一律显示「几点恢复」，「空间无额度」只用于真的被空间 credits 卡住的账号

### 功能
- 额度用完自动切号，并在被打断的对话里自动发「继续」
- 切号顺序：字母轮转 / 重置最近优先 / 剩余最多优先；可把账号排除出轮换
- 回合结束后自动继续（默认关，每个对话有次数上限）
- 自动开始计时：5 小时窗口还没开始的账号由后台逐个起算（默认关）
- 额度、重置券、团队订阅、成员交费台账、会话监控、消息中心

---

Download the zip, unzip, and drag the app into Applications (macOS 14+, Apple silicon). The build is ad-hoc signed and not notarized — see the README for first-launch steps.

New in this release: quiet background switching (ChatGPT no longer jumps to the front), per-account "skip rotation" with a grouped account table, and the status column now shows when an exhausted account recovers.
