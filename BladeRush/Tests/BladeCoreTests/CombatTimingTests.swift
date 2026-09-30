import XCTest
@testable import BladeCore

/// Runs the combat timing / systems checks from BladeCore.SelfTests as XCTest cases.
/// (The same checks run without XCTest via `BladeSim selftest`.)
final class CombatTimingTests: XCTestCase {
    private func run(_ name: String) {
        guard let entry = SelfTests.all.first(where: { $0.0 == name }) else { return XCTFail("missing test \(name)") }
        let c = SelfTests.Checker()
        entry.1(c)
        for f in c.failures { XCTFail("\(name): \(f)") }
    }

    func testParryWindows() { run("parryWindows") }
    func testPerfectParryBoundaries() { run("perfectParryBoundaries") }
    func testUnblockables() { run("unblockables") }
    func testBlockAfterWindow() { run("blockAfterWindow") }
    func testDodgeIFrames() { run("dodgeIFrames") }
    func testPerfectDodge() { run("perfectDodge") }
    func testTimingAssistAndHardMode() { run("timingAssistAndHardMode") }
    func testCounterStance() { run("counterStance") }
    func testInputBuffer() { run("inputBuffer") }
    func testPostureMath() { run("postureMath") }
    func testPostureRecovery() { run("postureRecovery") }
    func testStamina() { run("stamina") }
    func testStrikeTimeline() { run("strikeTimeline") }
    func testChainedTimeline() { run("chainedTimeline") }
    func testSweptHitboxes() { run("sweptHitboxes") }
    func testMathBasics() { run("mathBasics") }
    func testJSONDefaults() { run("jsonDefaults") }

    /// Every data file loads and passes validation (boss rules: no ranged attacks, etc.).
    func testDataValidates() {
        let data = GameDataStore()
        XCTAssertEqual(data.weapons.count, 5)
        XCTAssertEqual(data.encounters.count, 54)
        XCTAssertTrue(data.problems.isEmpty, data.problems.joined(separator: "\n"))
        for (_, b) in data.bosses {
            let n = data.resolveAttacks(b).filter { !$0.hardOnly && !$0.signature }.count
            XCTAssertGreaterThanOrEqual(n, 8, "\(b.id) has too few attacks")
            XCTAssertGreaterThanOrEqual(b.phases.count, 2, "\(b.id) needs at least 2 phases")
        }
    }

    /// A short scripted fight runs deterministically without NaNs.
    func testHeadlessFight() {
        let data = GameDataStore()
        guard let enc = data.encounters["gorrik"] else { return XCTFail("no gorrik") }
        let world = World(data: data, encounter: enc, playerWeapons: data.weapons, startWeapon: 0, playerVisual: PlayerLook.visual(),
                          hardMode: false, timingAssist: 1, quality: 0.25)
        let bot = PlayerBot(skill: 0.9, perfectBias: 0.5, seed: 1)
        for _ in 0..<(60 * 20) {
            let (inputs, move) = bot.think(world: world, dt: 1.0 / 60)
            world.update(realDt: 1.0 / 60, inputs: inputs, moveInput: move, look: .zero)
            _ = world.drainEvents()
            XCTAssertTrue(world.player.fighter.position.x.isFinite)
        }
    }
}
