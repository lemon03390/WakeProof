//
//  ShareCardModel.swift
//  WakeProof
//
//  Wave 5 H5 (§12.3-H5): pure-logic helpers for the opt-in Share card. The
//  SwiftUI view itself (`ShareCardView`) is rendered offscreen via
//  `ImageRenderer` and is hard to unit-test directly; everything that can be
//  teased out into a pure function lives here so tests can exercise it
//  without instantiating a view or the ImageRenderer pipeline.
//
//  Hooked source signals:
//  - HOOK_S7_7 (social reward via one-tap share): a minimalist card the user
//    can post to IG Story / WhatsApp turns the streak into a visible social
//    artefact without the product auto-posting anything.
//  - HOOK_S4_5 (逆反心理防禦與自主權保障 — autonomy preservation): default
//    off; user must enable via settings toggle. Forced share = abandonment
//    risk. The gate below encodes the opt-in requirement so callers can't
//    accidentally bypass it.
//

import CoreGraphics
import Foundation

/// Static helpers factored out of the View so the canvas-size constants and
/// the share-button visibility gate are unit-testable without instantiating
/// a SwiftUI view. Kept as an `enum` with no cases so instances can't exist —
/// these are pure functions.
enum ShareCardModel {

    // MARK: - Canvas constants

    /// Portrait width. Matches Instagram Story's native resolution at 1x so
    /// the rendered PNG uploads without re-scaling. 1080x1920 is also a
    /// standard TikTok / Snapchat / WhatsApp Status dimension — covering the
    /// three surfaces the demo will most likely show.
    static let canvasWidth: CGFloat = 1080

    /// Portrait height. 9:16 aspect ratio with `canvasWidth`.
    static let canvasHeight: CGFloat = 1920

    /// The 9:16 portrait size as a `CGSize` so callers pass a single value
    /// into `ImageRenderer` or frame modifiers.
    static let canvasSize: CGSize = CGSize(width: canvasWidth, height: canvasHeight)

    // MARK: - UserDefaults keys

    /// Stage 8 IMPORTANT 5 fix: single source of truth for the "user opted
    /// in to sharing" UserDefaults key. Previously duplicated as a string
    /// literal across `AlarmSchedulerView` (the toggle) and
    /// `MorningBriefingView` (the consumer gate) — a typo in either site
    /// would silently desync the two surfaces. Consolidating here means the
    /// compiler catches any future drift and any @AppStorage wrapper
    /// referencing the key reads from one place.
    static let shareCardEnabledKey = "com.wakeproof.shareCardEnabled"

    // MARK: - Copy constants

    /// The caption under the large streak number. Pinned as a constant (not
    /// a computed property) so a test can assert the exact string and catch
    /// an accidental copy edit before it ships.
    static let streakCaption = "day streak"

    /// The watermark/mark in the bottom-right corner of the card. Deliberately
    /// just "WakeProof" — no tagline, no URL — to keep the card visually
    /// minimal and the shared artefact ambiguous enough that it reads as a
    /// personal achievement post rather than an ad.
    static let markLabel = "WakeProof"

    /// The ShareLink button copy shown under "Start your day" in
    /// MorningBriefingView. Phrased in second-person present so it reads as
    /// the user's action ("share this morning") rather than a product prompt
    /// ("Share your streak!"). Pinned for test parity.
    static let shareButtonCopy = "Share this morning"

    // MARK: - Gate helpers

    /// The visibility gate for the Share button in MorningBriefingView.
    /// Returns `true` only when ALL of the following hold:
    ///   1. The user has opted in (`enabled`). Default off per HOOK_S4_5.
    ///   2. The current streak is >= 1. A zero-streak user has nothing
    ///      meaningful to share; a "0-day streak" card would be a weird
    ///      artefact to post.
    ///
    /// Observation nullability is intentionally ignored here: a user whose
    /// Claude observation is nil this morning (pre-H1 attempt, Claude didn't
    /// emit, etc.) can still share the streak number alone. The card's view
    /// layer handles the nil-observation case by skipping that text block.
    static func shouldShowShareButton(
        enabled: Bool,
        streak: Int,
        observation: String?
    ) -> Bool {
        // The `observation` parameter is preserved in the signature so a future
        // revision (e.g. "only share when there's both a streak AND an
        // observation") can flip the rule without a caller signature change.
        // Today we use it only to document the intent; the decision itself is
        // solely a function of `enabled` + `streak`.
        _ = observation
        guard enabled else { return false }
        guard streak >= 1 else { return false }
        return true
    }
}
