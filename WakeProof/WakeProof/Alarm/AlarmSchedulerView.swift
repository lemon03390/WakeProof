//
//  AlarmSchedulerView.swift
//  WakeProof
//
//  The post-onboarding home screen: configure the wake window, toggle the alarm,
//  and (DEBUG) fire immediately for demo video capture.
//

import SwiftUI
import os

struct AlarmSchedulerView: View {

    /// `actor` reference — passed by constructor because SwiftUI's `.environment(_:)`
    /// refuses non-`@Observable` types. See WakeProofApp.body for the rationale.
    /// Only the DEBUG buttons read this; the release build never touches it.
    let overnightScheduler: OvernightScheduler

    @Environment(AlarmScheduler.self) private var scheduler
    @Environment(AudioSessionKeepalive.self) private var audioKeepalive
    @Environment(PermissionsManager.self) private var permissions
    @Environment(WeeklyCoach.self) private var weeklyCoach

    @State private var startTime: Date = .now
    @State private var isEnabled: Bool = false

    /// R9 fix: mirrors the actor-local error from OvernightScheduler so the
    /// banner can surface "overnight analysis couldn't start tonight — we'll
    /// retry next launch". Refreshed on view appear. A successful
    /// `startOvernightSession` clears the actor's copy; we refresh on next
    /// app-active bounce so the banner clears without a manual reload.
    ///
    /// SQ5 (Stage 4): renamed from `overnightStartError` to match the scheduler
    /// actor's accessor (`lastSessionStartError()`). AlarmSchedulerView is
    /// already scoped to the overnight domain — the `overnight` prefix was
    /// redundant and made grep harder when tracing the value through storage →
    /// accessor → View.
    @State private var lastSessionStartError: String?

    private let logger = Logger(subsystem: LogSubsystem.alarm, category: "schedulerView")

    var body: some View {
        NavigationStack {
            Form {
                if let banner = systemBanner {
                    Section {
                        Text(banner)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Wake window") {
                    DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                    Toggle("Alarm enabled", isOn: $isEnabled)
                }

                Section {
                    Button("Save & schedule") { save() }
                }

                if let next = scheduler.nextFireAt {
                    Section("Next fire") {
                        Text(next.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                #if DEBUG
                Section("DEBUG") {
                    Button("Fire alarm now") { scheduler.fireNow() }
                        .foregroundStyle(.red)
                    Button("Start overnight session now") {
                        // B3: the scheduler now holds the single source of truth
                        // for "is a session already open" (sessionCreationInFlight
                        // + UserDefaults re-check on the actor). No pre-actor
                        // TOCTOU guard needed; calling this repeatedly is safe.
                        Task { await overnightScheduler.startOvernightSession() }
                    }
                    Button("Finalize briefing now") {
                        Task {
                            // B5: finalizeBriefing now returns a `BriefingResult`
                            // enum rather than `BriefingDTO?`. DEBUG logging
                            // mirrors the three cases so you can tell at a
                            // glance whether the pipeline succeeded, had no
                            // session, or hit a failure path.
                            let result = await overnightScheduler.finalizeBriefing(forWakeDate: .now)
                            switch result {
                            case .success(let dto):
                                logger.info("Debug finalize: success briefingText=\(dto.briefingText, privacy: .public)")
                            case .noSession:
                                logger.info("Debug finalize: noSession (no active handle)")
                            case .failure(let reason, let message):
                                logger.info("Debug finalize: failure reason=\(reason.rawValue, privacy: .public) message=\(message, privacy: .public)")
                            }
                        }
                    }
                }
                #endif

                Section {
                    WeeklyInsightView(
                        insight: weeklyCoach.currentInsight,
                        generatedAt: weeklyCoach.generatedAt
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }
            .navigationTitle("WakeProof")
            .onAppear(perform: loadFromScheduler)
            // R9: refresh the overnight error banner snapshot whenever the
            // view comes back into focus. Quick one-shot poll of the actor;
            // the property is actor-local so we have to hop.
            .task { await refreshOvernightStartError() }
        }
    }

    /// R9 helper: pull the latest overnight-start error from the scheduler
    /// actor. Called on `.task` so it runs once per view appearance, covering
    /// both "just came back from background" and "just navigated to this
    /// tab". Extracted as its own method so tests can exercise it without
    /// reaching into `body`.
    private func refreshOvernightStartError() async {
        lastSessionStartError = await overnightScheduler.lastSessionStartError()
    }

    /// Composite "the alarm contract is partially broken" banner. Surfaces the highest-impact
    /// problem first so the user knows what to fix; without this, denied notifications and
    /// dead audio sessions silently pretended the alarm was armed. Optional permissions land
    /// at the bottom — they degrade features but don't break the wake-up contract.
    ///
    /// Priority order: alarm-breaking conditions first (notifications / audio),
    /// then HealthKit (disables summary), then the overnight pipeline (Layer 3
    /// analysis feature — failure is visible to the user only via the morning
    /// briefing card, which is less immediate than the alarm itself). The
    /// overnight error is surfaced so users know why the briefing card will
    /// say "unavailable" — without this banner the failure is invisible until
    /// the next wake.
    private var systemBanner: String? {
        if permissions.notifications == .denied {
            return "Notifications are off — WakeProof can't reliably wake you. Open Settings → WakeProof → Notifications."
        }
        if let audioError = audioKeepalive.lastError {
            return "Audio session problem: \(audioError) The alarm may not survive lock screen."
        }
        // HealthKit failure doesn't break the alarm but disables the last-night summary.
        // Surface so the user knows why the feature is silent. `.failed` (transient/hardware)
        // is more actionable than `.denied` (user chose no).
        if permissions.healthKit == .failed {
            return "Apple Health unavailable — last-night summary won't appear."
        }
        // R9: overnight session kickoff failed. Surfaces below the core-alarm
        // banners because a broken briefing doesn't prevent wake-up — the
        // alarm still fires, the user still verifies, they just don't get
        // Claude's morning prose. Message ends with the retry hint so the
        // user knows no manual action is required.
        if let overnightErr = lastSessionStartError {
            return "Overnight analysis couldn't start tonight: \(overnightErr). We'll retry next launch."
        }
        return nil
    }

    private func loadFromScheduler() {
        let w = scheduler.window
        startTime = WakeWindow.composeTime(hour: w.startHour, minute: w.startMinute)
        isEnabled = w.isEnabled
    }

    private func save() {
        let startComponents = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        let hour: Int
        let minute: Int
        if let h = startComponents.hour, let m = startComponents.minute {
            hour = h
            minute = m
        } else {
            // Calendar.dateComponents on a Date should always produce hour/minute. If it ever
            // doesn't, fall back to defaults but loudly — silent defaulting saved a 22:00
            // alarm as 06:30 in an earlier draft of this code.
            logger.error("DateComponents fallback fired for startTime=\(startTime, privacy: .public) — defaulting to 06:30")
            hour = 6
            minute = 30
        }
        let w = WakeWindow(
            startHour: hour,
            startMinute: minute,
            // End-time UI is intentionally absent — the model field is preserved for a
            // future flexibility-window feature; the previously-saved value is carried
            // forward so the JSON-encoded UserDefaults blob stays decodable.
            endHour: scheduler.window.endHour,
            endMinute: scheduler.window.endMinute,
            isEnabled: isEnabled
        )
        scheduler.updateWindow(w)
    }

}
