**下载下面的 `ChatGPT-Accounts-x.y.zip`，解压后把「ChatGPT 账号」拖进「应用程序」。** 需要 macOS 14+、Apple 芯片。

安装包没有做苹果公证：第一次打开时到「系统设置 → 隐私与安全性」点「仍要打开」，或在终端执行
`xattr -dr com.apple.quarantine "/Applications/ChatGPT 账号.app"`。

### 本版更新
- **英文界面**：设置 → 窗口 → 语言（跟随系统 / 中文 / English），切换后 App 自动退出再重开；消息中心、日志里以前写下的中文也按当前语言显示
- **重置券按账号（空间）分开**：同一个邮箱在不同团队空间里的券各是各的，详情、表格、确认弹窗都按槽位显示；修好了在第二个空间点「重置」提示失败（no_credit）的问题
- 默认续答用语跟着语言走（中文「继续」/ English "Continue"），自己改过的不动
- 会话页：模型列对齐，各列收紧，操作列不再超出窗口

### 功能
- 额度用完自动切号，并在被打断的对话里自动发「继续」
- 切号顺序：字母轮转 / 重置最近优先 / 剩余最多优先；可把账号排除出轮换
- 回合结束后自动继续（默认关，每个对话有次数上限）
- 自动开始计时：5 小时窗口还没开始的账号由后台逐个起算（默认关）
- 额度、重置券、团队订阅、成员交费台账、会话管理、消息中心
- 中文 / English 界面

---

Download the zip, unzip, and drag the app into Applications (macOS 14+, Apple silicon). The build is ad-hoc signed and not notarized — see the README for first-launch steps.

New in this release: an English UI (Settings → Window → Language; the app relaunches itself, and older notices and logs are shown in the current language); reset credits tracked per account/workspace, fixing the "no_credit" failure when the same email sits in two workspaces; the default resume prompt follows the language; tidier Sessions columns.
