// Scripted player bot for headless simulations (BladeSim) and balance checks.
// It reads telegraphs like a player would: parries white/gold/purple, dodges red,
// punishes openings and performs deathblows.
import Foundation

public final class PlayerBot {
    public var skill: Float          // 0..1: chance to react correctly
    public var perfectBias: Float    // chance a parry is timed perfectly
    private var rng: Rng
    private var cooldown: Double = 0
    private var reactedAttack = -1
    private var reactedStrike = -1

    public init(skill: Float = 0.8, perfectBias: Float = 0.5, seed: UInt64 = 7) {
        self.skill = skill
        self.perfectBias = perfectBias
        rng = Rng(seed: seed)
    }

    /// Returns inputs for this frame and the analog move vector.
    public func think(world: World, dt: Double) -> ([TimedInput], Vec2) {
        var inputs: [TimedInput] = []
        var move = Vec2.zero
        let p = world.player
        guard let boss = world.aliveBosses.first else { return ([], .zero) }
        if p.lockTarget == nil { world.toggleLockOn() }
        cooldown -= dt
        let bf = boss.fighter
        let dist = vlength(vflat(bf.position - p.fighter.position)) - bf.radius - p.fighter.radius
        func press(_ a: PlayerAction, at offset: Double = 0) {
            inputs.append(TimedInput(action: a, pressed: true, offset: offset))
            inputs.append(TimedInput(action: a, pressed: false, offset: min(dt, offset + 0.05)))
        }
        // Defense: react to the incoming strike.
        if boss.state == .attacking, let mv = bf.move, let st = mv.strike, !st.feint {
            let tta = mv.timeline.timeToActive / mv.timeline.speed
            let key = mv.attackId * 100 + mv.timeline.index
            if tta > 0 && tta < 0.09 && reactedStrike != key && dist < 5 {
                reactedStrike = key
                if rng.chance(skill) {
                    if st.telegraph == .red || st.hitbox == .grab {
                        press(.dodge, at: max(0, tta - 0.06))
                    } else {
                        let perfect = rng.chance(perfectBias)
                        press(.parry, at: max(0, tta - (perfect ? 0.03 : 0.1)))
                    }
                }
                return (inputs, move)
            }
        }
        // Offense.
        let canPunish = boss.state == .recovering || boss.state == .flinch || boss.state == .neutral || boss.canBeDeathblowed
        if p.fighter.healthFraction < 0.35 && p.flasks > 0 && dist > 3 && cooldown <= 0 {
            press(.heal); cooldown = 1.2
        } else if canPunish && dist < 1.4 && cooldown <= 0 && (p.state == .locomotion || p.state == .attacking) {
            if p.abilityReady && rng.chance(0.3) { press(.ability) } else if rng.chance(0.2) { press(.heavy) } else { press(.light) }
            cooldown = 0.18
        }
        if dist > 1.2 { move = Vec2(0, 1) } else if dist < 0.5 { move = Vec2(0, -0.6) } else { move = Vec2(rng.chance(0.5) ? 0.4 : -0.4, 0) }
        _ = reactedAttack
        return (inputs, move)
    }
}
