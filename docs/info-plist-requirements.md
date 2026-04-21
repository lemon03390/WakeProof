# Info.plist & Capabilities Requirements

Every iOS permission we touch needs (a) a usage description string in Info.plist and (b) in some cases a target capability enabled. Missing any of these crashes the app at runtime when the permission is requested.

## Capabilities to enable in Xcode target

Open `WakeProof.xcodeproj` → target `WakeProof` → **Signing & Capabilities** tab → **+ Capability**:

1. **Background Modes** — check these boxes:
   - ✅ Audio, AirPlay, and Picture in Picture (required for overnight audio session)
   - ✅ Background fetch (optional, for overnight analytics path)
   - ❌ Do NOT check others unless proven necessary — judges will scan Info.plist

2. **HealthKit** — enabled, no provisioning profile changes needed.

3. **Critical Alerts entitlement** — requires Apple approval we will not have for this hackathon. Request it in Info.plist anyway (shows intent); if denied, the app gracefully falls back to regular local notifications. Add the entitlement request to `WakeProof.entitlements`:
   ```xml
   <key>com.apple.developer.usernotifications.critical-alerts</key>
   <true/>
   ```
   The user will still see the permission prompt; iOS will deny without Apple's sign-off, and that's fine — document it in the demo narration.

## Info.plist keys (copy verbatim)

Paste these into `Info.plist`. The usage description strings appear in iOS permission prompts — tone them consistently with WakeProof's self-commitment-device positioning.

```xml
<key>NSCameraUsageDescription</key>
<string>WakeProof needs the camera to verify you're actually out of bed when your alarm rings. We take one photo per wake attempt, stored locally on your device.</string>

<key>NSHealthShareUsageDescription</key>
<string>WakeProof reads your sleep data from Apple Health to show you a summary of last night's rest when you successfully wake up.</string>

<key>NSMotionUsageDescription</key>
<string>WakeProof uses motion data to detect your natural awakening window and time your alarm to a lighter sleep phase. Motion stays on your device.</string>

<key>NSUserNotificationsUsageDescription</key>
<string>WakeProof sends alarm notifications so you wake up on time, even if the app is backgrounded.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>WakeProof does not require location access. (This key is only present because a dependency requests it.)</string>

<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>fetch</string>
</array>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>WakeProof optionally saves your baseline reference photo to your Photos library as a backup.</string>
```

## Target minimum iOS version

**iOS 17.0** — we rely on `@Observable`, SwiftData, and Interactive Widgets. Bumping up doesn't gate any reviewer with a modern device.

## Build configuration

- Swift version: 5.10+
- Use Swift strict concurrency checking: `-strict-concurrency=complete` if time permits; `minimal` if not.
- Optimization: `-O` for Release, default for Debug.

## For the demo

Before recording the demo video, **double-check** every usage description string in Info.plist reads well in the permission prompt. Judges may see these briefly in your video — they should not say "TODO" or "Usage description needed".
