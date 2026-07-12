# Contributing to MoniArc

感谢你愿意参与 MoniArc。

## 提交问题

请说明 macOS 版本、Mac 型号、Codex 安装方式、可复现步骤和预期行为。公开 issue 前请移除用户名、项目路径、任务标题、提示词、代码、token 和其他隐私信息。

## 提交代码

1. Fork 仓库并从 `main` 创建分支。
2. 保持改动聚焦，并为行为变化补充测试。
3. 运行 `xcodegen generate`。
4. 运行完整测试命令：

```sh
xcodebuild -project MoniArc.xcodeproj \
  -scheme MoniArc \
  -destination 'platform=macOS' \
  test CODE_SIGNING_ALLOWED=NO
```

5. 在 pull request 中说明用户可见变化、验证方式和隐私影响。

请不要提交真实 `~/.codex` 文件、账号信息或从真实会话提取的 fixture。
