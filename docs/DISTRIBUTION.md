# MoniArc 官网直发流程

MoniArc 采用 Developer ID 官网直发，不提交 Mac App Store。正式发布包必须启用 Hardened Runtime、使用 Developer ID Application 证书签名，并通过 Apple 公证。

## 无凭证的本地 DMG 检查

开发阶段可以在不访问 Apple 账号的情况下验证 Release App、DMG 目录和 Applications 快捷方式：

```sh
./scripts/build-local-dmg.sh
```

生成的文件名包含 `unsigned-preview`，App 只使用临时 ad-hoc 签名并启用 Hardened Runtime，只能用于本机结构检查，不得上传或分发。

## 一次性准备

1. 加入 Apple Developer Program。
2. 在 Xcode 登录开发者账号，并创建或下载 `Developer ID Application` 证书。
3. 在 Apple Developer 网站或 Xcode 中确认 Bundle ID `com.zhengzipeng.MoniArc` 属于发布团队。
4. 为 `notarytool` 保存凭证：

```sh
xcrun notarytool store-credentials MoniArcNotary \
  --apple-id "你的 Apple ID" \
  --team-id "你的 Team ID" \
  --password "App 专用密码"
```

凭证会保存在 macOS 钥匙串中，不应写入仓库。

## 构建、公证与生成 DMG

先运行不会访问 Apple 账号的本地发布检查：

```sh
./scripts/check-release-readiness.sh
```

再生成正式签名包：

```sh
cd MoniArc
DEVELOPMENT_TEAM="你的 Team ID" \
NOTARY_PROFILE="MoniArcNotary" \
./scripts/build-release.sh
```

脚本会按 Team ID 自动选择唯一的 `Developer ID Application` 身份。如果同一团队存在多个有效身份，请额外设置完整身份名称或证书 SHA-1：

```sh
DEVELOPER_ID_IDENTITY="Developer ID Application: 你的名称 (TEAMID)" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARY_PROFILE="MoniArcNotary" \
./scripts/build-release.sh
```

成功后，发布文件位于 `build/MoniArc-<版本>.dmg`。
DMG 内含 `MoniArc.app` 与 Applications 快捷方式，同时会生成相对路径 `.sha256` 文件。脚本会先在临时目录完整验证候选 DMG，只有签名、公证票据、版本、DMG 结构和校验值全部通过后，才替换 `build/` 中的发布文件。

## 发布前验证

```sh
./scripts/verify-release.sh build/MoniArc-<版本>.dmg
```

单独核对下载后的校验和时，必须在 DMG 与 `.sha256` 所在目录运行：

```sh
(
  cd build
  shasum -a 256 -c MoniArc-<版本>.sha256
)
```

还应在一台没有 Xcode、没有本项目源码的干净 Mac 上验证：

- DMG 能正常打开，App 可拖入 Applications；
- Gatekeeper 第一次启动不出现“开发者无法验证”；
- 未安装 Codex 时能安全显示断开状态；
- 安装并登录 Codex 后能显示额度与任务状态；
- 退出 MoniArc 后没有残留后台进程；
- 官网下载文件的 SHA-256 与 GitHub Release 一致。

## 发布清单

- 更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`；
- 更新 `CHANGELOG.md`；
- 运行完整测试；
- 生成并验证公证 DMG；
- 在产物目录运行 `shasum -a 256 -c MoniArc-<版本>.sha256`；
- 创建 Git tag 与 GitHub Release；
- 将 DMG 和校验值添加到 Release；
- 官网下载按钮指向该 GitHub Release 资源；
- 在两台不同 Mac 上完成安装与升级回归测试。
