import Foundation
import MotorCore

struct Sample: Identifiable, Sendable {
    let id = UUID()
    var time: Date
    var motorID: Int
    var position: Double
    var speed: Double
    var torque: Double
    var voltage: Double
    var temperature: Int
    var windingTemperature: Int
    var error: UInt32 = 0
    var warning: Int = 0
    var timedOut = false
    var mode = 0
    var encoderPosition: Double = 0
    var raw = ""
    var demo = false
    var command = MotorCommand()
    var commandFrequency: Double = 0

    init(_ feedback: MotorFeedback) {
        time = .now; motorID = feedback.id; position = feedback.position
        speed = feedback.speed; torque = feedback.torque; voltage = feedback.voltage
        temperature = feedback.temperature; windingTemperature = feedback.windingTemperature
        error = feedback.error; warning = feedback.warning; timedOut = feedback.timedOut
        mode = feedback.mode; encoderPosition = feedback.encoderPosition; raw = feedback.raw.hex
    }
    init(demoID: Int, time: Date, phase: Double) {
        self.time = time; motorID = demoID; position = sin(phase) * 0.65
        speed = cos(phase) * 0.3; torque = sin(phase + 0.4) * 0.08
        voltage = 24.1; temperature = 32; windingTemperature = 35
        mode = 1; encoderPosition = position; demo = true
    }
}
