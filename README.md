# Motor Studio for macOS

面向宇树 **J288 / S288** 舵机的独立原生 Mac 调试客户端，使用 SwiftUI、AppKit 与 Darwin / IOKit 串口。macOS 26 使用 Liquid Glass，macOS 14–15 使用原生磨砂材质。

## 功能

- 单电机与多电机控制，输出端 / 转子端单位切换，同步 / 异步通信。
- 目标与反馈曲线、历史浏览、最长一小时原始记录、CSV 导出；数值与曲线显示目标 20 Hz，后台采集独立调度。
- ID 扫描、重复 ID 修复与重排、设备波特率、版本与序列号、APP 固件升级和上电位置标定。
- 启动前清除超时锁存并重新开启保护，全部确认后才进入控制；故障、超时或反馈模式不符时停止。

## 运行与构建

需要 macOS 14 或更新版本及 Xcode 26 / 对应 SDK。

```bash
cd macos
open Package.swift
# 或生成应用：
bash scripts/build-app.sh
```

[完整使用说明](macos/README.md) · [性能记录](macos/PERFORMANCE.md) · [验证记录](macos/VALIDATION.md)

## 验证状态

最新代码已通过 **64 项 macOS XCTest**、原生模型/采集/曲线运行测试及 Apple Silicon + Intel 通用版应用构建（[CI 验证记录](https://github.com/MCU-UAV/Motor-Studio-macOS/actions/runs/43501591589)）。Linux 的 64 项协议测试和真实采集引擎的有状态串口模拟测试也已通过。真实电机、串口时序、固件升级和完整 GUI 操作仍需实测；语言切换尚未实现，当前不承诺全部原版能力或硬件验收完成。

```bash
cd macos
swift test
python3 scripts/test-startup-runtime.py
```

[协议证据](macos/PROTOCOL.md) · [私有协议分析](macos/PRIVATE-PROTOCOL.md) · [原版功能对照](macos/Docs/Original/INSPECTION.md) · [状态审查](macos/Docs/STATE-AUDIT.md)

## 来源与许可证

基于 [Unitree-Motor-Assistant](https://github.com/unitreerobotics/Unitree-Motor-Assistant) 安装包行为分析及公开协议独立实现，不是宇树官方 Mac 发行版。本仓库仅发布原生工程、测试及分析资料，不包含 Windows EXE、DLL 或固件镜像。保留上游 [BSD 3-Clause 许可证与版权声明](LICENSE)。
