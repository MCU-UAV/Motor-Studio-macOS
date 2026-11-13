import Foundation
import MotorCore

enum ChartMetric: String, CaseIterable, Identifiable, Sendable {
    case position = "反馈位置", speed = "反馈速度", torque = "反馈扭矩"
    case targetPosition = "目标位置", targetSpeed = "目标速度", targetTorque = "目标扭矩"
    case kp = "位置增益", kd = "速度增益", encoder = "输出编码器"
    case temperature = "驱动温度", winding = "绕组温度", voltage = "电压"
    case motorID = "电机 ID", mode = "模式", timeout = "超时状态", frequency = "通信目标频率"
    var id: String { rawValue }
    var unit: String {
        switch self {
        case .position, .targetPosition, .encoder: return "rad"
        case .speed, .targetSpeed: return "rad/s"
        case .torque, .targetTorque: return "N·m"
        case .kp: return "N·m/rad"
        case .kd: return "N·m/(rad/s)"
        case .temperature, .winding: return "°C"
        case .voltage: return "V"
        case .frequency: return "Hz"
        default: return ""
        }
    }
    func value(_ sample: Sample, side: ControlSide) -> Double {
        switch self {
        case .position: return side.position(sample.position)
        case .speed: return side.position(sample.speed)
        case .torque: return side.torque(sample.torque)
        case .targetPosition: return side.position(sample.command.position)
        case .targetSpeed: return side.position(sample.command.speed)
        case .targetTorque: return side.torque(sample.command.torque)
        case .kp: return sample.command.converted(to: side).kp
        case .kd: return sample.command.converted(to: side).kd
        case .encoder: return sample.encoderPosition
        case .temperature: return Double(sample.temperature)
        case .winding: return Double(sample.windingTemperature)
        case .voltage: return sample.voltage
        case .motorID: return Double(sample.motorID)
        case .mode: return Double(sample.mode)
        case .timeout: return sample.timedOut ? 1 : 0
        case .frequency: return sample.commandFrequency
        }
    }
}
