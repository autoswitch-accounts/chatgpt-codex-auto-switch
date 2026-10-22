**下载下面的 `ChatGPT-Accounts-x.y.zip`，解压后把「ChatGPT 账号」拖进「应用程序」。** 需要 macOS 14+、Apple 芯片。

安装包没有做苹果公证：第一次打开时到「系统设置 → 隐私与安全性」点「仍要打开」，或在终端执行
`xattr -dr com.apple.quarantine "/Applications/ChatGPT 账号.app"`。

### 本版更新
- 会话页：每个对话可以**后台继续 / 暂停**，行首勾选、表头全选后批量操作，不用切到 ChatGPT
- 会话页：单独或批量**改模型、推理强度、速度**，当前值打勾，选项和叫法跟 ChatGPT 自己的菜单一致
- 撞限后先等同账号上还在跑的对话自己做完再切号，不再把它们打断
- 切号后续答直接排进 ChatGPT 的待发队列、在后台唤醒，几秒就接着跑
- 在本 App 暂停的对话单独标出，自动续答会跳过它；会话默认按最后活动排序
- Cloudflare 拦截团队 / 订阅 / 成员接口时，改用内置浏览器内核去取
- 团队页可以移除已停用的空间；侧栏卡片显示完整邮箱和额度进度条；成员、日志页更宽松；弹窗配色统一

### 功能
- 额度用完自动切号，并在被打断的对话里自动发「继续」
- 切号顺序：字母轮转 / 重置最近优先 / 剩余最多优先；可把账号排除出轮换
- 回合结束后自动继续（默认关，每个对话有次数上限）
- 自动开始计时：5 小时窗口还没开始的账号由后台逐个起算（默认关）
- 额度、重置券、团队订阅、成员交费台账、会话管理、消息中心

---

Download the zip, unzip, and drag the app into Applications (macOS 14+, Apple silicon). The build is ad-hoc signed and not notarized — see the README for first-launch steps.

New in this release: continue / pause conversations from the Sessions page (one at a time or a checked batch) without switching to ChatGPT; change model, reasoning effort and speed per conversation or in bulk; wait for running conversations to finish before switching accounts; background resume through ChatGPT's own queue; WebKit fallback when Cloudflare blocks team data.
