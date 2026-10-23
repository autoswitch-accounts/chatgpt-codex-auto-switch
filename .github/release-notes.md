**下载下面的 `ChatGPT-Accounts-x.y.zip`，解压后把「ChatGPT 账号」拖进「应用程序」。** 需要 macOS 14+、Apple 芯片。

安装包没有做苹果公证：第一次打开时到「系统设置 → 隐私与安全性」点「仍要打开」，或在终端执行
`xattr -dr com.apple.quarantine "/Applications/ChatGPT 账号.app"`。

### 本版更新
- **添加账号不再让当前账号失效**：以前添加账号时会在服务器端注销当时登录的账号，它存在 App 里的登录跟着失效、额度一直查不到；现在只清掉本机的登录。已经因此失效的账号会显示「需重新登录」，删掉后重新添加即可
- **登录失效的账号会被标出来**：查额度被拒时先自动刷新一次凭证，刷不了就标红「需重新登录」，自动切号也不再切过去
- **团队空间额度（credits）用完时续答更可靠**：不会因为额度显示「可用」就在同一个没额度的账号上反复发「继续」；切号前刚失败的那次「继续」，切号后会在新账号上再续一次
- **等待切号时点「继续」/「全部继续」马上生效**：当前账号用重置券恢复了就不切号、直接续答；还没恢复会发通知说明
- 会话页的「账号」列显示对话停下时所在的账号

### 功能
- 额度用完自动切号，并在被打断的对话里自动发「继续」
- 切号顺序：字母轮转 / 重置最近优先 / 剩余最多优先；可把账号排除出轮换
- 回合结束后自动继续（默认关，每个对话有次数上限）
- 自动开始计时：5 小时窗口还没开始的账号由后台逐个起算（默认关）
- 额度、重置券、团队订阅、成员交费台账、会话管理、消息中心
- 中文 / English 界面

---

Download the zip, unzip, and drag the app into Applications (macOS 14+, Apple silicon). The build is ad-hoc signed and not notarized — see the README for first-launch steps.

New in this release: adding an account no longer signs out the account that was in use (newer Codex versions revoke the login on sign-out, which left that account's saved login dead); accounts whose saved login was revoked are marked "Needs sign-in" and skipped by auto-switching; more reliable resuming when a workspace runs out of credits (no more repeated "Continue" on an account with nothing left, and a resume that failed right before a switch is retried on the new account); Continue / Continue All work while a switch is pending, and a reset credit used meanwhile keeps you on the current account; the Sessions page shows the account a conversation stopped on.
