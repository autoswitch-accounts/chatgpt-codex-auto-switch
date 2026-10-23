**下载下方的 `ChatGPT-Accounts-x.y.zip`，解压后将「ChatGPT 账号」拖入「应用程序」。** 系统要求：macOS 14 或更高版本，Apple 芯片。

安装包未经苹果公证。首次打开时，在「系统设置 → 隐私与安全性」中点击「仍要打开」，或在终端执行
`xattr -dr com.apple.quarantine "/Applications/ChatGPT 账号.app"`。

### 本版更新
- **添加账号不再使当前账号失效**：此前添加账号时会在服务器端注销当时登录的账号，导致 App 中保存的登录失效、无法查询额度；现在只清除本机的登录信息。已因此失效的账号显示「需重新登录」，删除后重新添加即可恢复
- **标记登录失效的账号**：查询额度被拒绝时先自动刷新凭证，刷新失败则标记为「需重新登录」，自动切号会跳过该账号
- **改进团队空间 credits 用完时的续答**：不再因额度显示为可用而在同一个无额度的账号上重复发送「继续」；切号前失败的续答会在切换后的账号上重试
- **等待切号期间「继续」/「全部继续」立即生效**：当前账号通过重置券恢复后不再切号，直接续答；尚未恢复时发送通知说明
- 会话页的「账号」列显示对话停止时所在的账号

### 功能
- 额度用完后自动切号，并在被中断的对话中发送「继续」
- 切号顺序：字母顺序 / 重置时间最近优先 / 剩余额度最多优先；可将账号排除在轮换之外
- 回合结束后自动继续（默认关闭，每个对话有次数上限）
- 自动开始计时：5 小时窗口尚未开始的账号由后台服务逐个开始计时（默认关闭）
- 额度、重置券、团队订阅、成员交费台账、会话管理、消息中心
- 中文 / English 界面

---

Download the zip, unzip it and move the app to Applications (macOS 14 or later, Apple silicon). The build is ad-hoc signed and not notarized; see the README for first-launch steps.

New in this release: adding an account no longer signs out the account in use (newer Codex versions revoke the login on sign-out, which invalidated that account's saved login); accounts whose saved login was revoked are marked "Needs sign-in" and skipped by auto-switching; improved resuming when a workspace runs out of credits ("Continue" is no longer sent repeatedly to an account with no quota left, and a resume that failed just before a switch is retried on the new account); Continue / Continue All take effect while a switch is pending, and if a reset credit restores the current account, no switch takes place; the Sessions page shows the account a conversation was on when it stopped.
