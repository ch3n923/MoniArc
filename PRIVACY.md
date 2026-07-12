# MoniArc 隐私说明

更新日期：2026-07-12

MoniArc 是在用户 Mac 本机运行的开源工具。项目维护者不会通过 MoniArc 收集、接收、出售或共享个人数据。

应用包内包含 Apple 格式的 `PrivacyInfo.xcprivacy`，声明不追踪用户、不连接追踪域名，也不收集离开设备的数据。

## 本机读取的数据

为了显示额度与任务状态，MoniArc 会在本机：

- 启动用户已安装的 Codex App Server，并读取其返回的额度窗口与连接状态；
- 以只读方式打开 `~/.codex/state_5.sqlite`；
- 以受限、只读方式读取 `~/.codex/sessions` 中近期 JSONL 文件末尾最多 8 MiB 的原始字节，并只解码任务生命周期所需的路由字段；
- 在内存中处理任务标识、标题、更新时间和运行状态。

JSONL 原始字节只在扫描期间短暂存在内存。MoniArc 不直接打开 `~/.codex/auth.json`，也不会从会话记录中提取、保留、显示或上传登录凭证、访问令牌、代码、完整提示词、回复正文或工具正文。

启动专用 Codex 子进程时，MoniArc 只转交运行所需的系统路径、区域设置、Codex/OpenAI 配置、代理和证书环境变量。GitHub、云服务、SSH agent、动态加载器等无关凭证不会转交；环境变量的值不会被记录或持久化。

## 数据如何使用

上述数据只用于在当前 Mac 的 MoniArc 界面中显示额度和状态。MoniArc 不包含项目自有服务器、遥测、广告、崩溃上报或第三方分析 SDK，也不会将这些数据发送给项目维护者。

退出 MoniArc 后，内存中的任务状态会被释放。MoniArc 只使用 `UserDefaults` 保存位置与光效偏好。

## 用户控制

- 随时退出 MoniArc 即可停止观察。
- 删除 MoniArc 后，可在 `~/Library/Preferences/com.moniarc.MoniArc.plist` 删除本地偏好。
- MoniArc 不修改 `~/.codex`；卸载 MoniArc 不会删除 Codex 数据。

## 第三方服务

MoniArc 依赖用户自行安装和登录的 Codex。用户与 Codex/OpenAI 之间的数据处理受其各自条款和隐私政策约束，不由本项目控制。

## 联系方式

在公开发布后，可通过 MoniArc GitHub 仓库的 issue 功能提交隐私问题。发布前不会收集任何联系信息。
