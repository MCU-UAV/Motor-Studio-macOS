import Foundation
import MotorCore

enum MotorTableRow: String, CaseIterable, Identifiable {
    case commandMode = "目标模式", protection = "超时保护", targetTorque = "目标扭矩 · N·m", targetSpeed = "目标速度 · rad/s"
    case targetPosition = "目标位置 · rad", kp = "位置增益", kd = "速度增益", communication = "通信状态"
    case idValue = "反馈 ID", mode = "反馈模式", timeout = "超时状态", torque = "反馈扭矩 · N·m", speed = "反馈速度 · rad/s"
    case position = "反馈位置 · rad", encoder = "输出编码器 · rad", driver = "驱动温度 · °C", winding = "绕组温度 · °C"
    case voltage = "电压 · V", error = "错误码", warning = "警告码"
    var id: String { rawValue }
    func value(sample: Sample?, command: MotorCommand?, side: ControlSide, running: Bool) -> String {
        let c = command?.converted(to: side)
        func number(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "—" }
        func modeName(_ value: Int?) -> String { value.map { $0 == 0 ? "Stop" : $0 == 1 ? "FOC" : String($0) } ?? "—" }
        switch self {
        case .commandMode: return modeName(c?.mode.rawValue)
        case .protection: return c.map { $0.timeoutProtection ? "开启" : "关闭" } ?? "—"
        case .targetTorque: return number(c?.torque)
        case .targetSpeed: return number(c?.speed)
        case .targetPosition: return number(c?.position)
        case .kp: return number(c?.kp)
        case .kd: return number(c?.kd)
        case .communication:
            guard let sample else { return "无反馈" }
            if sample.demo { return "演示" }
            if sample.error != 0 || sample.timedOut { return "异常" }
            return running ? (Date.now.timeIntervalSince(sample.time) < 0.5 ? "在线" : "反馈过期") : "上次反馈"
        case .idValue: return sample.map { String($0.motorID) } ?? "—"
        case .mode: return modeName(sample?.mode)
        case .timeout: return sample.map { $0.timedOut ? "已触发" : "正常" } ?? "—"
        case .torque: return number(sample.map { side.torque($0.torque) })
        case .speed: return number(sample.map { side.position($0.speed) })
        case .position: return number(sample.map { side.position($0.position) })
        case .encoder: return number(sample?.encoderPosition)
        case .driver: return sample.map { String($0.temperature) } ?? "—"
        case .winding: return sample.map { String($0.windingTemperature) } ?? "—"
        case .voltage: return number(sample?.voltage)
        case .error: return sample.map { String(format: "0x%08X", $0.error) } ?? "—"
        case .warning: return sample.map { String($0.warning) } ?? "—"
        }
    }
}
