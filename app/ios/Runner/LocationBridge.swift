import CoreLocation
import Flutter
import UIKit

/// iOS location bridge. Second-queue per the roadmap, but written App
/// Store-compatible from day 1: significant-location-change + region monitoring
/// for low battery, `allowsBackgroundLocationUpdates` for live sessions, and
/// `showsBackgroundLocationIndicator = true` (honesty — no hidden background
/// use). No private APIs. Mirrors the Android control channel contract so the
/// same Dart code drives both platforms.
class LocationBridge: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private let control: FlutterMethodChannel
    private let stream: FlutterMethodChannel
    private var reporting = false

    init(messenger: FlutterBinaryMessenger) {
        control = FlutterMethodChannel(name: "app.aul/control", binaryMessenger: messenger)
        // On iOS the fixes are delivered to the same isolate (foreground/BG task).
        stream = FlutterMethodChannel(name: "app.aul/bg", binaryMessenger: messenger)
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true

        control.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result)
        }
    }

    private func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
        switch call.method {
        case "startReporting":
            start()
            result(true)
        case "stopReporting":
            stop()
            result(true)
        case "isReporting":
            result(reporting)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func start() {
        manager.requestAlwaysAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        // Low-battery baseline; live-share/SOS switch to continuous updates.
        manager.startMonitoringSignificantLocationChanges()
        manager.startUpdatingLocation()
        reporting = true
    }

    private func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        reporting = false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let batt = batteryPercent()
        let payload: [String: Any?] = [
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
            "acc": loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
            "spd": loc.speed >= 0 ? loc.speed : nil,
            "hdg": loc.course >= 0 ? loc.course : nil,
            "batt": batt,
            "ts": Int(loc.timestamp.timeIntervalSince1970 * 1000),
        ]
        stream.invokeMethod("onLocation", arguments: payload)
    }

    private func batteryPercent() -> Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Int(level * 100) : nil
    }
}
