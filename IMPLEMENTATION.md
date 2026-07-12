# MoniArc 实现说明

## 运行时结构

```text
Codex App Server ── QuotaSource ─┐
                                ├─ IslandStore / Reducer ─ PanelDriver ─ NSPanel + SwiftUI
SQLite + FSEvents ─ TaskSource ──┤
NSScreen ──────── ScreenProvider ┤
Mouse monitors ── PointerSensor ─┘
```

所有异步事件由 `@MainActor IslandStore` 串行化。Reducer 只产生计时、刷新、布局与窗口提交 effect；计时回调携带 generation token，窗口回调携带 `PanelRevision`，过期结果会被忽略。

主要目录：

- `Domain/`：纯模型、Reducer、Store、系统/手动时钟。
- `Window/`：刘海几何、屏幕提供器、指针传感器及唯一 `NSPanel`。
- `UI/`：原生黑 SwiftUI 视图、状态描边和展示模型。
- `Data/Quota/`：Codex App Server JSONL transport、解析与重连。
- `Data/Tasks/`：SQLite 只读索引、FSEvents 与隐私安全生命周期扫描。
- `Harness/`：仅 Debug 编译的假源和控制窗口。

## 关键不变量

- 面板只使用 `orderFrontRegardless()`，不调用 `NSApp.activate()` 或 `makeKeyAndOrderFront()`。
- 自动覆盖要求刘海几何完整、刘海高度不超过 32pt、两翼各不小于 43pt。
- 窗口切换位置时先冻结旧 revision 并无动画收起，再接收新布局。
- 额度轮换只使用单调时钟；额度重置值是墙上时间 `Date`。
- 任务观察总预算为 32 个候选、8MiB/文件、32MiB/次刷新。
- 任务解析器只解码 envelope 类型、生命周期类型、状态、工具名和 call ID。

## Harness

`--harness` 提供：

- 运行 / 等待 / 错误 / 空闲 / 断开状态；
- 自动 / 覆盖 / 悬浮；
- 真实屏幕、185/198/218pt 刘海、异常窄翼、无刘海、负坐标外接和屏幕不可用；
- `+59.999s`、`+1ms`、`+10s`、`+30s` 的确定性单调时间推进；
- stale、缺失周额度、额度断线与恢复；
- Panel 起止 frame、动画时长、revision 和前台 PID 控制台记录。

Release 二进制通过 `#if DEBUG` 排除 Harness 控制器和字符串。
