# BLADE RUSH — Game Design & Technical Brief

> Source brief as provided by the project owner. This file is the source of truth for scope and rules.
> The development plan that implements it lives in [DevelopmentPlan.md](DevelopmentPlan.md).

You are building a high-intensity boss rush action game as a native macOS application. Read this entire document before writing any code. Then produce a detailed development plan split into milestones, list any technical risks you see.

---

## 1. Vision

A fast, punishing, precision-focused 3D boss rush. One playable character, five weapons, and 50+ handcrafted bosses fought back to back in dramatic arenas. Combat is the entire game. Every fight should feel like a duel where reading the enemy and timing your parries and dodges decides everything. Reference points for feel: Sekiro's parry and posture system, Hollow Knight's boss design clarity, and the hit impact of Devil May Cry.

The two pillars are:
1. Combat that feels incredible: responsive, weighty, readable, and fair.
2. The best visuals achievable on a Mac with zero external assets.

---

## 2. Technical Foundation (strict rules)

- Language: Swift 5.9+.
- Graphics: Metal and MetalKit, with a custom renderer written from scratch.
- Allowed frameworks: only Apple's built-in frameworks (Metal, MetalKit, MetalFX, simd, AppKit or SwiftUI for windowing and menus, GameController, AVFoundation/AVAudioEngine, Foundation).
- Zero third-party libraries, packages, or engines. Zero external asset files. No downloaded models, textures, fonts beyond system fonts, or audio files.
- Everything visual and audible is generated in code: meshes, materials, textures, animations, effects, and sound.
- Target: macOS 14+, optimized for Apple Silicon (M1 and newer), 60 FPS minimum on base M1, 120 FPS on ProMotion displays when possible.
- Build system: use Swift Package Manager plus a shell script that assembles a proper .app bundle (Info.plist, icon generated in code, ad-hoc codesigning). Compile Metal shaders either at build time with `xcrun metal` / `metallib` or at runtime from source. Choose whichever is more reliable and explain why.
- I can run terminal commands and play the game, but you can't see the screen. Build strong debug tooling (see section 13) so I can report problems precisely.

Suggested project structure (adjust if you have a better one):
- /Engine — renderer, math, scene, camera, input, audio, time
- /Engine/Shaders — all Metal shader code
- /Procedural — mesh generation, texture generation, animation authoring, audio synthesis
- /Game/Player — controller, weapons, combat state
- /Game/Bosses — AI framework, attack library, boss definitions
- /Game/Arenas — arena generation and lighting presets
- /Game/UI — HUD, menus, settings
- /Data — tuning configs and boss definitions as JSON
- /Tests — unit tests for combat timing and systems
- /Scripts — build, run, and package scripts

---

## 3. Rendering Pipeline (the "best graphics possible" goal)

Build a modern, high-end renderer. Implement in this priority order so the game looks good early and keeps improving:

Core:
- Physically based rendering (metallic/roughness workflow) with image-based lighting generated from a procedural sky.
- HDR rendering with ACES filmic tonemapping and per-arena color grading.
- Cascaded shadow maps with soft filtering (PCF or PCSS) and contact shadows.
- Forward+ or deferred shading (choose and justify) to support many dynamic lights from sparks, glowing weapons, and fire.

Post-processing:
- Temporal anti-aliasing (TAA) or MetalFX temporal upscaling with a quality/performance toggle.
- Bloom with physically plausible threshold and soft knee.
- Screen-space ambient occlusion (GTAO or HBAO quality).
- Screen-space reflections on wet or polished floors.
- Volumetric fog and light shafts (god rays) per arena.
- Per-object motion blur, depth of field during finishers and cinematic moments, subtle chromatic aberration and radial blur on big hits and perfect parries, film grain and vignette as optional settings.

Effects:
- GPU-driven particle system (compute shaders) for sparks, embers, dust, snow, ash, rain, and debris, capable of tens of thousands of particles.
- Weapon trails: smooth ribbon trails with emissive gradients, unique per weapon.
- Parry sparks: a bright, satisfying burst with light flash and short-lived point light.
- Ground impact decals and cracks for heavy attacks.
- Cloth simulation (Verlet or position-based dynamics) for capes, banners, robes, and scarves.
- Hair or fur strands as simple physics chains where it adds drama.
- Emissive materials for glowing weapon edges, runes, and boss eyes.
- Procedural skies: dusk, storm, eclipse, aurora, blood moon, underground, each with matching lighting.

Quality settings: Low, Medium, High, Ultra, plus individual toggles for each expensive effect, a resolution scale slider, and an FPS counter.

---

## 4. Art Direction and Procedural Content

Style: stylized dark fantasy with strong silhouettes, dramatic rim lighting, and high-contrast color. Think painted concept art brought to life. Readability comes first: the player must always be able to see what the boss is doing.

Character and boss geometry:
- Build characters from procedural meshes. Use signed distance fields with smooth blending, polished via marching cubes or dual contouring, or use carefully composed primitives with bevels and subdivision. Pick the approach that produces the most detailed, organic results and explain the choice.
- Each boss needs a distinct silhouette: size, proportions, armor shape, cloak, headgear, and weapon should make it recognizable at a glance.
- Generate normal detail procedurally (armor plates, engravings, fabric weave, scratches, rust).

Procedural textures and materials:
- Noise-based generators (Perlin, simplex, Worley, fBm, domain warping) for metal, stone, wood, leather, fabric, ice, obsidian, bone, and moss.
- Wear masks: edge scratches, dirt in crevices, rust on iron, frost on cold-themed bosses.
- Generate textures at load time and cache them.

Arenas:
- Each arena is generated from a theme preset: floor material, architecture pieces (pillars, ruins, arches, statues, broken walls), props, weather, sky, fog density, light color, and ambient particles.
- Arenas are circular or rectangular with clear boundaries, flat, readable ground, and no clutter that blocks the camera.

---

## 5. Animation System

- Skeletal animation system written from scratch: bones, skinning on the GPU, pose blending, additive layers.
- Author animations in code as keyframe data (poses defined per bone with timing and easing curves), stored in JSON so they can be tuned without recompiling.
- Follow animation principles for every attack: clear anticipation (wind-up), fast action, and readable follow-through and recovery. This is essential for fair telegraphs.
- Procedural layers on top: foot IK on the ground, look-at for head tracking, breathing idle, hit reactions, secondary motion on cloth and accessories.
- Root motion for attacks and dodges so movement matches animation.
- Smooth blending between locomotion (idle, walk, run, strafe) and combat states.

---

## 6. Player Character and Controls

Controls (fully rebindable, keyboard + mouse and controller support via GameController):
- Move, camera, lock-on target, light attack, heavy attack (hold to charge), weapon ability, parry, dodge, weapon swap (next/previous and a radial quick-select), heal, pause.

Camera:
- Third-person camera with lock-on. Smart framing that keeps both the player and boss in view, collision avoidance, smooth damping, and cinematic zoom during finishers.
- Camera shake system with intensity presets (light hit, heavy hit, parry, boss slam) and a setting to reduce or disable it.

Player resources:
- Health bar.
- Posture bar: fills when you block or get hit, breaks if full (brief stagger). Recovers when not under pressure.
- Stamina for dodges and heavy attacks. Punishes spamming without making the game sluggish.
- Ability meter per weapon, filled by landing hits, perfect parries, and perfect dodges.
- Limited healing (e.g. 3 flasks per fight, refilled between bosses in boss rush mode).

---

## 7. Core Combat Mechanics (the heart of the game)

All timing values live in one JSON tuning file with hot reload, so I can adjust feel while the game runs.

Parry:
- Parry window: 150 ms default (tunable).
- Perfect parry (first 60 ms of the window, tunable): deflects fully, deals heavy posture damage to the boss, triggers 80–120 ms hitstop, a bright spark burst, a ringing metal sound, and a brief camera punch.
- Normal parry: deflects but takes minor posture damage.
- Failed parry (too early or late): short recovery where the player is vulnerable. Parry has a small cooldown if pressed with nothing to parry so spamming is punished.

Dodge:
- Short dash with invincibility frames: 200 ms default (tunable).
- Perfect dodge (dodging within the last 100 ms before impact): triggers a 0.5-second slow-motion window, a visual afterimage, and a weapon-specific bonus.
- Dodge direction follows movement input; backstep if no input.

Boss posture and deathblows:
- Every boss has a posture bar. Parries, aggression, and heavy attacks fill it.
- When it breaks, the boss staggers and the player can perform a cinematic deathblow (a critical strike with camera zoom, slow motion, and depth of field) that deals massive damage or ends a phase.

Hit feel:
- Hitstop scaled by attack weight (light: 40 ms, heavy: 90 ms, perfect parry: 110 ms, deathblow: 250 ms).
- Hit flashes on the target, directional hit reactions, knockback, sparks on armor, and audio layered by weapon and material.
- Input buffering: 150 ms buffer so inputs pressed slightly early during recovery still execute.
- Animation canceling rules clearly defined: which moves can be canceled into dodge or parry, and at what frame.

Hitboxes:
- Precise weapon hitboxes that follow the blade through the swing (capsule sweeps between frames so fast swings never skip).
- Separate hurtboxes per body region.
- Active frames, startup frames, and recovery frames defined per attack in data.

---

## 8. The Five Weapons

The player can swap weapons mid-combat with a short swap animation (or instantly as part of a special "swap strike" if timed during a combo). Each weapon has its own full moveset, stats, trail color, sound profile, and unique interactions with parry and dodge.

1. Katana — balanced, precise, parry-focused
   - Light combo: 4-hit fast slash chain. Heavy: rising slash that launches smaller bosses.
   - Ability "Iaido Counter": sheathe into a stance. If a boss attack hits during the stance, auto-counter with a devastating draw cut.
   - Perfect parry bonus: next attack deals double posture damage.
   - Perfect dodge bonus: a free instant counter-slash.

2. Greatsword — slow, heavy, posture breaker
   - Light combo: 3 wide sweeping swings. Heavy: chargeable overhead with 3 charge levels.
   - Ability "Earthsplitter": a leaping slam that cracks the ground in a line, with hyper armor during the swing.
   - Perfect parry bonus: the parry itself staggers the boss briefly.
   - Perfect dodge bonus: next heavy attack charges instantly.

3. Twin Daggers — fastest weapon, aggressive, dodge-focused
   - Light combo: 6-hit flurry. Heavy: spinning double stab.
   - Ability "Blood Dance": a rapid multi-hit sequence that applies stacking bleed. Dodging during it extends the combo.
   - Perfect parry bonus: instant riposte flurry.
   - Perfect dodge bonus: brief invisibility-afterimage that confuses the boss for 1 second.

4. Spear — longest reach, thrust-based, spacing control
   - Light combo: 3 rapid thrusts. Heavy: sweeping arc that hits everything in range.
   - Ability "Vaulting Strike": pole-vault over the boss or an incoming attack and strike downward.
   - Perfect parry bonus: pushes the boss back and opens a guaranteed thrust.
   - Perfect dodge bonus: auto-lunge that closes distance.

5. Kusarigama (chain sickle) — mid-range, technical, crowd and control
   - Light combo: close sickle slashes mixed with chain swings. Heavy: wide spinning chain orbit.
   - Ability "Chain Pull": throw the chain to grab the boss and yank them toward you. If it lands during a boss wind-up, it interrupts the attack.
   - Perfect parry bonus: wraps the boss's weapon, disarming them briefly.
   - Perfect dodge bonus: the chain auto-lashes out and hits the boss.

Each weapon needs clear stats: damage, posture damage, speed, reach, stamina cost, and ability meter cost, all tunable in JSON.

---

## 9. Bosses

### Weapon rules (strict)
- Every boss fights with a close-range or mid-range held weapon.
- Allowed: swords, axes, maces, hammers, spears, polearms, scythes, whips, chain weapons, flails, dual blades, daggers, shields used offensively, and anything held in the hand that strikes up close or at mid-range.
- Forbidden: bows, crossbows, guns, throwing weapons, thrown projectiles, magic projectiles, and any long-range attack. Every attack must come from the weapon or the boss's body movement while holding it.
- Elemental effects (fire, ice, lightning, shadow) are allowed only as visual trails or short-range area bursts on weapon contact, never as projectiles.
- No unarmed fighting: no punches, kicks, or grabs without the weapon.

### Telegraph language (consistent across all bosses)
- White flash on the weapon: parryable.
- Red glow: unblockable, must dodge.
- Purple shimmer: delayed or feint attack, timing is offset.
- Gold flash: a combo ender that opens a big punish window if parried perfectly.
- Every telegraph also has a distinct audio cue so players can react by sound.

### Boss AI framework
- Hierarchical state machine with weighted attack selection based on distance, phase, cooldowns, and recent history (no repeating the same attack three times in a row).
- Adaptive behavior: bosses notice player habits. If the player spams dodge, bosses use more delayed attacks. If the player spams parry, they mix in more unblockables.
- Spacing behavior: circling, stepping in, stepping back, pressure strings, and deliberate openings after big attacks.
- Phase transitions at health thresholds with a short cinematic (new weapon stance, weapon glows, arena lighting shifts, music intensifies).
- All attacks are composed from a shared attack library defined in data, so each boss is built from JSON rather than custom code where possible.

### Attack library (build these as reusable building blocks)
Horizontal sweep, vertical overhead, diagonal slash, thrust, lunge, spin attack, leaping slam, ground-sweeping low attack (must jump or dodge), delayed swing, feint into real attack, multi-hit combo strings (3–8 hits), grab using the weapon (e.g. chain wrap or hooked blade), shield bash, charge attack across the arena, whirlwind, weapon-swap mid-combo, and area burst on weapon impact.

### Roster: 50 bosses in 10 themed tiers, plus gauntlets and a final boss
Design all bosses in full detail. For each boss, create: name, title, lore line, visual description, weapon, stats, 8–15 attacks, 2–3 phases, signature move, and weaknesses. Difficulty ramps across tiers.

1. The Outcast Yard (tutorial tier): rusted blades. Shortsword, hand axe, club, machete, falchion. Teaches parrying, dodging, and reading telegraphs.
2. The Iron Garrison: disciplined soldiers. Longsword and shield, halberd, mace, war pick, arming sword and buckler.
3. The Crimson Monastery: warrior monks. Bo staff, three-section staff, naginata, twin tonfa, meteor hammer.
4. The Drowned Harbor: pirates and sea raiders. Cutlass, boarding axe, anchor on a chain, held harpoon, hook blades.
5. The Ashen Forge: smiths and giants. Warhammer, molten greatblade, flail, maul, giant cleaver.
6. The Frost Citadel: ice knights. Zweihänder, glaive, frost rapier, lance, bardiche.
7. The Hollow Court: noble duelists. Rapier, dual sabers, sword cane, rapier and parrying dagger, estoc.
8. The Storm Peaks: lightning-touched warriors. War fan, chain whip, twin kama, storm spear, guandao.
9. The Eclipse Sanctum: shadow assassins. Dual katars, reaper scythe, kusarigama, urumi (whip sword), twin shadow blades.
10. The Throne of Blades: legendary champions who switch between multiple weapons mid-fight.

Gauntlets (3 fights): two bosses from earlier tiers at once, with coordinated attack patterns.
Final boss "The Blade Sovereign": uses all five of the player's weapons, mirrors the player's abilities, and has 4 phases.

Total: 54 boss encounters.

---

## 10. Game Modes and Progression

- Campaign Rush: fight tiers in order. Clearing a tier unlocks the next.
- Boss Select: replay any defeated boss.
- Endless Gauntlet: random bosses back to back, with a score and personal best.
- Hard Mode (unlocked after beating the final boss): tighter timing windows, faster bosses, new attacks.
- Between fights: a short prep screen to choose your starting weapon and view the next boss's name and title.
- Rewards: unlockable weapon skins (procedural color and material variants) and trail effects for achievements like "no-hit" or "only perfect parries."

---

## 11. Audio (fully procedural with AVAudioEngine)

- Synthesize all sound effects in code: metal clashes, parry rings (layered resonant tones), whooshes scaled by weapon speed, heavy impacts, footsteps per floor material, cloth movement, ambient wind, rain, fire crackle.
- Spatial 3D audio for boss attacks so players can hear direction.
- Procedural adaptive music: drums, bass, and synthesized choir or string pads that build in intensity with the fight, change on phase transitions, and drop out dramatically during deathblows.
- Distinct audio cue per telegraph type (section 9).
- Volume sliders for master, music, effects, and UI.

---

## 12. UI and UX

- Main menu with a dramatic animated background (a live 3D scene with the player character standing in an arena).
- HUD: player health, posture, stamina, ability meter, current weapon icon, heal count. Boss name, title, health bar, and posture bar at the top or bottom of the screen.
- Weapon radial menu with slow motion while open.
- Pause menu, settings, controls remapping, and a stats screen (deaths per boss, perfect parries, best times).
- Death screen with the option to retry instantly (under 2 seconds to be back in the fight).
- Accessibility: timing assist slider (widens parry/dodge windows), screen shake intensity, flashing effects toggle, colorblind-friendly telegraph mode (adds shapes and patterns to the color cues), subtitles for boss dialogue.
- Clean, stylish UI typography using system fonts, with smooth animated transitions.

---

## 13. Debug and Development Tools

Since you can't see the game, build tools that let me describe problems precisely:
- Debug overlay (toggle with a key): FPS, frame time, draw calls, GPU time per render pass.
- Hitbox and hurtbox visualization.
- Frame data display: current attack's startup, active, and recovery frames, and parry/dodge window timing shown live.
- Boss AI debug: current state, chosen attack, and weights.
- Free camera mode.
- Boss select cheat and invincibility toggle for testing.
- Slow-motion toggle (0.25x, 0.5x) to check timing.
- Screenshot key that saves to the desktop.
- Logging to a file that I can paste back to you.

---

## 14. Save System

- Save progress as JSON in ~/Library/Application Support/BladeRush/.
- Store unlocked tiers, defeated bosses, best times, stats, settings, and unlocked skins.
- Autosave after every boss.

---

## 15. Performance Requirements

- 60 FPS minimum at 1080p on base M1 with High settings, 120 FPS where possible on ProMotion.
- Use GPU-driven techniques where they help: compute-based particles, instancing for arena props, frustum culling, LOD for procedural meshes.
- Triple buffering and proper CPU/GPU synchronization.
- Load times under 5 seconds per arena (cache generated textures and meshes).
- Profile regularly and report bottlenecks.

---

## 16. How to Work

1. Read this entire document and propose a milestone plan.
2. Suggested milestone order (adjust if you have a better approach):
   - M1: Window, Metal renderer basics, camera, input, debug overlay.
   - M2: PBR lighting, shadows, HDR, tonemapping, procedural sky, and a test arena.
   - M3: Procedural character mesh, skeletal animation, locomotion.
   - M4: Core combat: attacks, hitboxes, parry, dodge, posture, hitstop, camera shake.
   - M5: All 5 weapons with full movesets and abilities.
   - M6: Boss AI framework, attack library, telegraph system.
   - M7: Tier 1 (5 bosses) fully playable and polished. Stop and let me play-test thoroughly.
   - M8: Post-processing and effects pass (bloom, SSAO, volumetrics, particles, trails, cloth).
   - M9: Procedural audio and adaptive music.
   - M10–M14: Remaining tiers, two at a time, with play-test checkpoints.
   - M15: Gauntlets and final boss.
   - M16: Menus, progression, save system, settings, accessibility.
   - M17: Performance optimization, .app packaging, final polish.
3. After each milestone, give me the exact terminal commands to build and run, tell me what to test, and wait for my feedback before continuing.
4. Keep all tuning values (timing, damage, stats, boss attack data) in JSON with hot reload.
5. Write clean, well-organized, commented Swift. Write unit tests for combat timing logic (parry windows, i-frames, input buffering, posture math).
6. Commit to git after each milestone with a clear message.
7. If something in this document is technically unrealistic, tell me directly and propose the best alternative instead of silently cutting it.
