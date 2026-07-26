import Foundation
import AppKit

// Pet mode: whether the pet may show, what it reacts to, and its schedule.

extension AppState {
    var petMood: PetMood { PetEngine.mood(for: petContext) }

    /// 0...1 across the current activity. Frozen while the user is petting, so
    /// scratching the pet's head genuinely stops the clock on its retreat.
    func petProgress(at date: Date = Date()) -> Double {
        guard petActivityDuration > 0 else { return 0 }
        var held = petHeldSeconds
        if let since = petPettingSince { held += date.timeIntervalSince(since) }
        let elapsed = date.timeIntervalSince(petActivityStart) - held
        return min(1, max(0, elapsed / petActivityDuration))
    }

    /// One 4 Hz heartbeat drives everything: it retires finished activities,
    /// tucks the pet away the moment the notch stops being at rest, and starts
    /// the next unprompted performance when its turn comes round. A single
    /// timer (rather than a chain of one-shots) means the pet can always be
    /// interrupted on the very next tick, whatever it was doing.
    func startPetDriver() {
        guard petEnabled else { return }
        petTimer?.invalidate()
        petNextActionAt = Date().addingTimeInterval(PetEngine.nextDelay(mood: .calm, using: &petRNG))
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.petTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        petTimer = t
    }

    private func petTick() {
        guard petEnabled else {
            if petActivity != .tucked { endPetActivity() }
            return
        }
        let now = Date()
        let ctx = petContext

        // A card opened / Claude started working while the cursor sat on the
        // pet: the pet loses, real content wins. Checked before the petting
        // freeze below, or it would never run. A demo is exempt — it was asked
        // for explicitly, and it's the only way to watch a rare activity.
        if petActivity != .tucked, !petDemoing, !ctx.allowsAutonomy || ctx.isWorking || ctx.isThinking {
            endPetActivity()
            return
        }
        // Being petted freezes the timeline — bank the held time and stop here
        // so nothing else can yank the pet away mid-scratch.
        if petPetting { return }
        if let since = petPettingSince {
            petHeldSeconds += now.timeIntervalSince(since)
            petPettingSince = nil
        }

        if petActivity != .tucked {
            guard petProgress(at: now) >= 1 else { return }
            // Walking the Demos menu's "Play All" list, one activity per turn.
            if petDemoing, !petDemoQueue.isEmpty {
                beginPetActivity(petDemoQueue.removeFirst())
                return
            }
            // A boop interrupted something — put the pet back where it was,
            // at the point in the performance it had reached.
            if let resume = petInterrupted {
                petInterrupted = nil
                beginPetActivity(resume.activity, elapsed: resume.elapsed)
                return
            }
            endPetActivity()
            return
        }

        guard now >= petNextActionAt else { return }
        // "Reduce motion" means the pet stops moving on its own. It still
        // answers a boop — that motion is one the user just asked for.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            petNextActionAt = now.addingTimeInterval(30)
            return
        }
        guard ctx.allowsAutonomy, !ctx.isWorking, !ctx.isThinking else {
            // Not the moment. Check back soon rather than burning the slot.
            // Not the moment (hovering, a card is open, Claude is busy). Check
            // back shortly rather than burning the slot on a full-length delay,
            // which would make the pet vanish for minutes after every hover.
            petNextActionAt = now.addingTimeInterval(5)
            return
        }
        // Random antics turned off: the pet stays put unless this is a genuine
        // reaction (a turn just finished or failed), which is event-driven, not
        // random. Boops still work — they don't come through here.
        guard petRandomEnabled || ctx.justFinished || ctx.justFailed else {
            petNextActionAt = now.addingTimeInterval(5)
            return
        }
        let activity = PetEngine.pickActivity(mood: PetEngine.mood(for: ctx), using: &petRNG)
        guard activity != .tucked else {
            petNextActionAt = now.addingTimeInterval(4)
            return
        }
        beginPetActivity(activity)
    }

    private func beginPetActivity(_ activity: PetActivity, elapsed: Double = 0) {
        petActivityDuration = PetEngine.duration(of: activity, using: &petRNG)
        petActivityStart = Date().addingTimeInterval(-elapsed)
        petHeldSeconds = 0
        petPettingSince = petPetting ? Date() : nil
        petActivity = activity
        if activity == .spiderHang { playSpiderTheme() }
    }

    private func playSpiderTheme() {
        guard !soundMuted else { return }
        guard let url = Bundle.main.url(forResource: "spiderman-meme-song", withExtension: "mp3") else { return }
        // Stop the previous run before starting a new one, or clicking the demo
        // twice stacks two tracks playing over each other.
        spiderSound?.stop()
        let sound = NSSound(contentsOf: url, byReference: true)
        spiderSound = sound
        sound?.play()
    }

    private func endPetActivity() {
        // Read these before they're reset: the next silence is proportional to
        // the performance that just ended.
        let finished = petActivity
        let lasted = petActivityDuration
        petDemoing = false
        petDemoQueue.removeAll()
        petInterrupted = nil
        petActivity = .tucked
        petActivityDuration = 0
        petHeldSeconds = 0
        petPettingSince = nil
        petPetting = false
        // The Spider-Pet's theme goes with him: when he climbs back into the
        // notch, the music stops instead of playing on to an empty notch.
        if finished == .spiderHang { spiderSound?.stop() }
        petNextActionAt = Date().addingTimeInterval(
            PetEngine.nextDelay(mood: petMood, after: finished, lasting: lasted, using: &petRNG)
        )
    }

    /// The user clicked the pet (or the bare notch). Always answers — a pet
    /// that ignores a poke isn't a pet. Whatever it was doing is resumed
    /// afterwards from the same point, so a boop feels like an interruption
    /// rather than a reset.
    func petBoop() {
        guard petEnabled else { return }
        let now = Date()
        // Boops within a couple of seconds of each other build a streak; the
        // fifth one tips the pet into a backflip. Pause and the streak resets.
        petBoopStreak = now.timeIntervalSince(petLastBoopAt) < 2.0 ? petBoopStreak + 1 : 1
        petLastBoopAt = now
        if petActivity != .tucked, petActivity != .boop, petActivity != .spin, petActivity != .celebrate {
            petInterrupted = (petActivity, petProgress() * petActivityDuration)
        }
        if petBoopStreak >= 5 {
            petBoopStreak = 0
            petInterrupted = nil
            beginPetActivity(.spin)
        } else {
            beginPetActivity(.boop)
        }
    }

    /// A turn just finished: give the pet a couple of seconds to notice and
    /// hop about it, once the notch settles back to idle.
    func petCelebrate() {
        guard petEnabled else { return }
        petCelebrateUntil = Date().addingTimeInterval(8)
        petNextActionAt = Date().addingTimeInterval(1.2)
    }

    /// Something went wrong: a turn died, or you denied a command. The pet jumps.
    /// Immediate, unlike the celebration — a fright has no delay in it.
    ///
    /// The window is generous because a failure usually raises a card, and the
    /// pet is not allowed to perform over a card the user is reading. It has to
    /// still be startled when that card clears, or it would sleep through the
    /// one event it exists to react to.
    func petStartle() {
        guard petEnabled else { return }
        petStartleUntil = Date().addingTimeInterval(14)
        petCelebrateUntil = .distantPast   // a dead turn did not finish
        petNextActionAt = Date()
    }

    /// Demos menu: perform these activities back to back, right now, whatever
    /// else is going on. Turns Pet Mode on if it was off — you asked to see the
    /// pet, so here is the pet.
    func demoPet(_ activities: [PetActivity]) {
        guard let first = activities.first else { return }
        if !petEnabled { setPetEnabled(true) }
        petDemoQueue = Array(activities.dropFirst())
        petDemoing = true
        petInterrupted = nil
        // Starts on the spot: the Demos > Pet rows keep the menu open, so the
        // pet performs in the notch while you pick the next one.
        beginPetActivity(first)
    }

    func setPetEnabled(_ on: Bool) {
        petEnabled = on
        if on {
            startPetDriver()
        } else {
            petTimer?.invalidate()
            petTimer = nil
            endPetActivity()
        }
        schedulePersist()
    }

    func setPetRandomEnabled(_ on: Bool) {
        petRandomEnabled = on
        // Turning it off shouldn't yank a performance already underway — the
        // tick simply won't start a new unprompted one. Turning it on lets the
        // next idle slot pick up naturally, so nothing else to do here.
        schedulePersist()
    }

    /// One-time post-update card: "Updated to vX — <highlights>".
    func showWhatsNewCard(version: String) {
        enqueuePermission(PermissionRequest(
            kind: .notification,
            title: "Updated to v\(version)",
            detail: Self.whatsNewHighlights,
            toolName: "WhatsNew",
            source: "ClaudeNotch",
            cwd: "",
            resolver: { _, _ in }
        ))
    }

    // MARK: - Usage stats

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
