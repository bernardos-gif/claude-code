# Blade Rush — Development Plan

**Status: draft v1, awaiting review.** No game code yet. Source brief: [DesignBrief.md](DesignBrief.md).

## Milestone status

| # | Milestone | Status |
|---|---|---|
| M1 | Foundation and feedback loop | Not started |
| M2 | Lighting and the first arena | Not started |
| M3 | Characters and animation | Not started |
| M4 | Combat core and hit feel | Not started |
| M5 | The five weapons | Not started |
| M6 | Boss framework, attack library, telegraphs | Not started |
| M7 | Tier 1 — play-test gate | Not started |
| M8 | Effects and post-processing | Not started |
| M9 | Audio and adaptive music | Not started |
| M10 | Tiers 2 + 3 | Not started |
| M11 | Tiers 4 + 5 | Not started |
| M12 | Tiers 6 + 7 | Not started |
| M13 | Tiers 8 + 9 | Not started |
| M14 | Tier 10 | Not started |
| M15 | Gauntlets and the Blade Sovereign | Not started |
| M16 | Menus, progression, save, settings, accessibility | Not started |
| M17 | Performance, packaging, polish | Not started |

---

## 1. Summary

Swift and Metal, Apple frameworks only, every mesh, texture, animation, effect and sound generated in code. The plan follows the brief's milestone order with five adjustments:

1. **M4 ships with a sparring automaton, first sparks and trails, and first synthesized clash and parry sounds.** Parry feel can only be judged against something that attacks you, with impact you can see and hear.
2. **Telegraph audio cues arrive with the telegraphs in M6**, ahead of the full audio pass in M9, so "react by sound" is testable in the tier 1 play-test.
3. **Performance is measured from M2 onward** with a benchmark mode and per-pass budgets. M17 is the final pass, and every milestone before it reports numbers.
4. **Settings persistence and the accessibility options that affect play-testing** (timing assist, shake intensity, flashing toggle) arrive by M7. Full menus stay in M16.
5. **M1 builds the feedback loop**: CI on a macOS runner, capture mode, replays and bug-report bundles, because I can't see the screen or compile Metal code in my environment.

---

## 2. Where the code lives

The repository root holds Elemental Clash (Three.js). Blade Rush lives in `BladeRush/` with its own `Package.swift`, and the two projects stay independent. Moving it to its own repository later keeps history (`git subtree split`).

```
BladeRush/
  Package.swift
  Sources/
    BladeCore/      Portable Swift with zero Apple-only imports. Compiles on macOS and Linux.
      Math/         vectors, matrices, quaternions, dual quaternions, curves, easing, deterministic trig
      Sim/          fixed-step clock, time scales, hitstop, seeded RNG, event log, replay format
      Combat/       fighter state machine, attacks, hit detection, parry/dodge/posture, buffering, cancels
      AI/           hierarchical state machine, attack selection, habit model, spacing
      Animation/    skeleton, clips, sampling, blending, IK, root motion, swing synthesis
      Physics/      XPBD cloth, chains, capsule collision
      Procedural/   noise, SDF modeling kit, meshing, decimation, weapon generators
      AudioDSP/     oscillators, filters, envelopes, modal synthesis, music sequencing (renders Float buffers)
      Data/         Codable schemas: tuning, weapons, attacks, bosses, arenas, animations, saves
      Lint/         frame-data fairness checks
    BladeEngine/    macOS: window, display link, input, Metal renderer, GPU generators,
                    AVAudioEngine host, hot reload, debug tools
    BladeGame/      macOS: player, bosses, arenas, UI, game modes (glue between Core and Engine)
    BladeRush/      executable entry point
    BladeTools/     portable CLI: data lint, headless fights, replay runner, mesh preview to PNG
  Shaders/          .metal sources, one file per pass family
  Data/             tuning.json, weapons/, attacks/, animations/, bosses/tier01…/, arenas/, skies/
  Tests/BladeCoreTests/
  Scripts/          doctor.sh, build.sh, run.sh, test.sh, package.sh, capture.sh, bench.sh
  Docs/             DesignBrief.md, DevelopmentPlan.md, per-tier boss design sheets
```

Mapping to the brief's suggested structure: `/Engine` → `BladeEngine` plus `BladeCore/Math` and `Sim`; `/Engine/Shaders` → `Shaders/`; `/Procedural` → `BladeCore/Procedural` plus the GPU generators in `BladeEngine`; `/Game/*` → `BladeGame/*`; `/Data`, `/Tests`, `/Scripts` as suggested.

The one structural change is the `BladeCore` split. Everything that decides combat outcomes compiles and runs its tests without Metal or AppKit: on your Mac, on CI, and in my Linux container.

---

## 3. Key technical decisions

### 3.1 Shader compilation: runtime from source, with offline validation

Shaders ship as `.metal` source and compile at launch with `MTLDevice.makeLibrary(source:options:)`. CI and `Scripts/build.sh --validate-shaders` also compile them offline with `xcrun metal` whenever the Metal toolchain exists, to catch errors early. Release packaging embeds a precompiled `default.metallib` when the toolchain is present and falls back to source.

Why this is the more reliable path:
- Runtime compilation needs only the macOS SDK, which the Command Line Tools include. The offline `metal` compiler ships only with full Xcode, and since Xcode 26 it is a separate download (`xcodebuild -downloadComponent MetalToolchain`). Build-time compilation would make every build depend on that setup.
- Compile errors land in the log with file and line, ready to paste.
- Shaders hot-reload: save a `.metal` file and its pipelines rebuild while the game runs.
- Startup cost stays small: pipelines build on background threads, and `MTLBinaryArchive` caches compiled pipelines between launches.

### 3.2 Frame loop, pacing and latency

- `CAMetalLayer` driven by `CADisplayLink` (`NSView.displayLink`, available from macOS 14, the minimum OS). It paces to 60 Hz or 120 Hz ProMotion and follows the display.
- Three frames in flight guarded by a semaphore, per-frame ring buffers for uniforms. A "Low latency" setting drops to two drawables.
- Simulation at a fixed 120 Hz with render interpolation; on a 60 Hz display that is two ticks per frame.
- The drawable is acquired as late as possible, only for the final composite.
- Every input event carries its hardware timestamp (`NSEvent.timestamp`, `GCController` `lastEventTimestamp`). Parry and dodge judgments use the press time, so frame rate and hitches never change whether a parry was perfect.
- MetalFX frame interpolation (macOS 26) stays off: generated frames add latency, and parry timing can't afford it.

### 3.3 Shading: clustered Forward+ with a thin pre-pass

Frame order:
1. Compute: particle simulation; character pre-skinning once per frame (reused by shadows, pre-pass and main pass; the previous frame's result is kept for motion vectors); cloth vertex upload.
2. Shadows: four cascades. Static arena geometry is cached and re-rendered only when the sun moves; dynamic casters draw on top. A dedicated high-resolution shadow map covers the fighters.
3. Pre-pass: depth, normal + roughness, motion vectors.
4. Hi-Z pyramid, clustered light culling on a froxel grid, GTAO, contact shadows.
5. Froxel volumetric fog, reusing the light clusters and the cascades.
6. Opaque forward pass with full per-material shading, then sky.
7. SSR, masked to wet or polished floor materials.
8. Transparents: particles, trails, afterimages, telegraph glows.
9. TAA or MetalFX temporal upscaling.
10. Motion blur, depth of field, bloom.
11. ACES tonemap, 3D LUT grade, chromatic aberration, radial blur, grain, vignette.
12. HUD, menus, debug overlay.

Why Forward+:
- Per-material shaders give full freedom for the stylized look: rim light, cloth sheen, anisotropic metal, emissive runes, frost, wet surfaces.
- Particles, trails and other transparents use the same clustered light lists, so sparks and fire light the scene consistently.
- The pre-pass provides exactly the buffers that GTAO, SSR, TAA/MetalFX, motion blur and contact shadows need. A deferred G-buffer would have to be written to memory for those same effects, which removes the bandwidth advantage deferred shading has on Apple's tile-based GPUs.
- Apple GPUs' hidden surface removal keeps the forward pass free of opaque overdraw.
- The froxel grid serves both light culling and volumetric fog.

### 3.4 Characters: SDF sculpting for organic forms, parametric hard-surface for weapons

- **Bodies, armor sculpts, cloak rest shapes, creature features**: signed distance fields built from primitives with smooth unions, chamfer and groove operators, and noise displacement. Evaluated on the GPU into a narrow-band grid, meshed with dual contouring (surface nets first, QEF-based sharp features added for armor edges), decimated with quadric error simplification into three LODs, and cached on disk by a hash of the definition.
- **Weapons and crisp trims**: parametric generators (profile extrusion, loft, lathe, bevels). Clean edges, simple UVs for emissive edge gradients, and an exact blade line that the hitbox and trail systems share.

Why SDF for the organic parts:
- Smooth blending gives organic joins (shoulders into torso, fabric folds) that composed primitives can't match.
- Skin weights come from the field: each primitive is bound to a bone, and the smooth-union blend factors become vertex weights, so joints bend smoothly.
- The field also yields per-vertex ambient occlusion, curvature and cavity, which drive the wear masks from the brief: scratches on convex edges, dirt in crevices, rust, frost.
- Materials use triplanar projection in bind-pose space, so textures stick to the skin while it deforms and no UV unwrapping is needed.

Skinning uses dual quaternions, which keep volume at twisting wrists and shoulders.

### 3.5 Animation: shared skeleton, key poses, swing synthesis

- One humanoid skeleton topology (about 55 bones, including weapon, cloth and accessory attach points) for the player and every boss. Bosses change proportions, so any clip plays on any boss, with root motion scaled by leg length.
- Clips live in JSON as key poses with timing and easing curves, including anticipation and overshoot curves.
- Attacks are authored as **swing specs**: the weapon-tip path (arc, thrust line, spin), key poses for anticipation, contact, follow-through and recovery, and body commitment (step, twist, crouch). A solver turns each spec into a clip, with two-bone IK keeping hands on the weapon. This keeps roughly 700 attack animations tractable as data.
- Procedural layers: foot planting IK, look-at, breathing, directional hit reactions, spine and head lag, secondary motion on cloth, hair and accessories.
- Blend trees for 8-direction locomotion and a combat layer with cancel-aware transitions.

### 3.6 Combat simulation model

- Player and bosses share one **Fighter** core: state machine, attacks, hitboxes, posture. The player drives it with input, bosses with AI intents. The Blade Sovereign reuses the player's movesets through it.
- Every timing value is authored in milliseconds; tick counts are derived.
- Weapon hitboxes are capsules along the blade line. Each tick sweeps from the previous blade pose to the current one with sub-steps, so a blade tip at 30 m/s never skips a hurtbox. Chain weapons use a chain of capsules along an authored guide curve.
- Deterministic: fixed step, seeded RNG, deterministic trig in simulation code. This enables replays and headless tests.

### 3.7 Audio: synthesized at load, mixed live

- Effects are synthesized in code at load time into buffers, with 4–8 random variants each, cached on disk: modal synthesis for metal clashes and parry rings, filtered noise for whooshes, wind and rain, membrane models for impacts.
- Playback runs through AVAudioEngine player-node pools into an `AVAudioEnvironmentNode` with HRTF, so boss attacks carry direction. Per-arena reverb through `AVAudioUnitReverb`.
- Music is generated in code as per-tier stems (drums, bass, pads, formant choir) rendered at load and sequenced on bar boundaries. Intensity layers add and remove stems as the fight heats up, phase changes trigger transitions, and deathblows cut to silence and a single hit.
- Why: the real-time audio thread only mixes prepared buffers, which avoids glitches from Swift allocation or reference counting inside a render callback, while everything stays procedural.

### 3.8 UI

HUD and menus are drawn by the Metal renderer with a signed-distance-field text atlas generated at launch from system fonts. This gives controller navigation everywhere, animated transitions and one visual style. AppKit handles the window, the menu bar and an optional debug tuning window.

### 3.9 Decals: floor overlay texture

Arenas are flat and bounded, so impact cracks, scorch marks, frost and wet patches are painted by compute into a floor overlay texture (albedo, normal, emissive for glowing cracks) that the floor shader samples. Thousands of marks cost the same as one.

### 3.10 Cloth, hair and chains

XPBD on the CPU with SIMD: a few thousand particles in total, sub-stepped, colliding with bone capsules and the floor plane. Gameplay never depends on cloth. For chain weapons, the authored guide curve decides hits and physics adds visual follow-through.

### 3.11 Data and hot reload

- Tuning, weapons, attacks, animations, bosses, arenas and skies are JSON under `Data/`.
- A watcher polls modification times twice a second, which survives editors that save by replacing the file. A file that fails to parse keeps its previous values and logs the error with path and position.
- Resource locator: runs from the repository read `BladeRush/Data` and `BladeRush/Shaders` directly, so edits apply live. The packaged `.app` reads `Contents/Resources`. SwiftPM resource bundles stay out of the build, since their expected location breaks `.app` code signing.

### 3.12 Language, frameworks and build settings

- `swift-tools-version` 5.9 with the Swift 5 language mode. Swift 6 strict concurrency adds friction across Metal and AppKit callbacks with no benefit for a game loop that owns its threads explicitly.
- Scripts always build optimized (`-c release` with debug symbols). Unoptimized Swift runs vector math ten or more times slower, which would make every play-test misleading.
- Frameworks: Metal, MetalKit, MetalFX, simd, AppKit, GameController, AVFoundation, Foundation. QuartzCore (`CAMetalLayer`, `CADisplayLink`) and `os` (signposts for Instruments) come along as parts of AppKit and Metal.

---

## 4. How we work: the feedback loop

I work in a Linux cloud container: I can't compile Metal or AppKit code or see the screen. These tools close the gap, in order of value:

1. **CI on a macOS runner** (GitHub Actions) builds everything, runs the tests, compiles the shaders offline and lints the data. I read the logs directly and fix compile errors before you pull. On a private repository, macOS minutes count 10× against the Actions quota.
2. **Portable core**: combat, AI, animation, meshing and audio DSP compile on Linux, so I can run unit tests, headless fights and mesh previews myself. This needs a Swift toolchain in my container; `download.swift.org` is currently blocked by this environment's network policy.
3. **Capture mode**: `./Scripts/capture.sh <set>` renders scripted shots to PNG (boss turntables, attack key poses, arenas under each sky, telegraph colors, HUD) plus a contact sheet. You commit the `captures/` folder and I look at the images.
4. **Replays and bug bundles**: F8 saves the last 60 s of input with the seed, plus log, settings, screenshot and GPU timings, into one folder. Committed, it lets me reproduce the fight in the headless simulator and read the exact event timeline.
5. **Logs** in `~/Library/Logs/BladeRush/latest.log`. Every parry and dodge judgment is logged with its offset, e.g. `PARRY perfect: hit 38 ms after press (perfect 0–60, window 0–150)`.
6. **Benchmark**: `./Scripts/bench.sh` flies a scripted camera path through an arena and prints average and 99th-percentile GPU time per pass.

Per milestone: I post exact commands, a test checklist and known issues; you play and report; I fix; then the milestone commit. Smaller commits happen along the way.

Commands (created in M1):

```bash
cd BladeRush
./Scripts/doctor.sh        # checks macOS, Swift, Xcode or Command Line Tools, Metal toolchain, GPU
./Scripts/build.sh         # optimized build + BladeRush/build/BladeRush.app
./Scripts/run.sh           # runs from the repo with hot reload, logs to the terminal
./Scripts/test.sh          # unit tests + data lint
./Scripts/package.sh       # final .app with icon, Info.plist, ad-hoc signature
```

Full Xcode is optional for building and useful for Instruments and GPU frame capture when we profile.

---

## 5. Milestones

Each milestone lists deliverables, what you test, and the exit criteria. M2, M3, M4 and M8 are the heaviest.

### M1 — Foundation and feedback loop

Deliverables
- Package with its five targets, the scripts above, the CI workflow.
- `.app` assembly: `Info.plist`, icon rendered in code and converted with `iconutil`, ad-hoc signature.
- AppKit window (resizable, fullscreen toggle); `CAMetalLayer` + `CADisplayLink` loop; triple buffering; fixed 120 Hz simulation with interpolation.
- Input: keyboard and mouse through `NSEvent` with raw mouse deltas via `GCMouse`; controllers through GameController; action map with rebinding data in JSON; input timestamps.
- Free camera and a basic orbit camera; test scene of procedural shapes.
- SDF text from system fonts; debug overlay with FPS, CPU and GPU frame time, per-pass GPU time (stage-boundary counters, which Apple GPUs support per pass), draw calls.
- Logging to file, screenshot key, hot reload for JSON and shaders, settings file.
- Test target with the first tests.

You test: scripts, window, frame pacing on your display, overlay numbers, a controller, screenshots, editing a JSON value while the game runs.

Exit: CI green, `test.sh` passes, stable frame pacing on your Mac.

### M2 — Lighting and the first arena

Deliverables
- PBR (GGX, Smith, Schlick, multi-scatter energy compensation), RGBA16F HDR targets.
- Procedural sky: physical atmosphere for dusk plus hooks for the stylized presets. Sky → cubemap → prefiltered specular mips, spherical-harmonic irradiance, BRDF LUT.
- Auto-exposure from a luminance histogram, ACES tonemap, per-arena grading through a 3D LUT built in code.
- Cascaded shadows (four cascades, texel snapping, PCF; PCSS on Ultra), static cascade caching, contact shadows, fighter shadow map.
- Pre-pass, Hi-Z, clustered light culling, a many-light test with 100+ point lights.
- GPU noise library (Perlin, simplex, Worley, fBm, domain warping) and first materials: stone, metal, wood.
- Arena generator v1: circular yard with floor, pillars, ruins and arches, instanced props, driven by a theme JSON.
- TAA v1, quality preset scaffold, capture mode, benchmark mode.

You test: the look of the arena, shadow stability while the camera moves, sky switching on a debug key, captures and benchmark output.

Exit: the arena scene stays under 8 ms GPU at 1080p on base M1, leaving budget for characters and post.

### M3 — Characters and animation

Deliverables
- SDF modeling kit (primitives, smooth and chamfer operators, displacement, material IDs, bone binding) with GPU evaluation, meshing, decimation, LODs and disk cache.
- Skin weights, AO, curvature and cavity baked per vertex; triplanar materials (metal, leather, fabric, bone) with wear masks.
- Shared skeleton; compute pre-skinning with dual quaternions.
- Clip format, sampler, blending, additive layers, root motion, 8-way locomotion blend tree, foot planting IK, look-at, breathing.
- Player character model and katana generator.
- `BladeTools` mesh preview (CPU rasterizer to PNG) so I can inspect silhouettes myself; capture sets for turntables and animation contact sheets.

You test: running around the arena; foot sliding, silhouette, material read, camera follow.

Exit: the player costs under 1.5 ms GPU including shadows; cached load under 2 s.

### M4 — Combat core and hit feel, against a sparring automaton

Deliverables
- Fighter core: attack data (startup, active, recovery, cancel windows, hitbox, damage, posture), capsule sweeps with sub-steps, hurtbox regions.
- Parry (perfect, normal, failed, whiff cooldown); dodge (i-frames, perfect-dodge detection, slow motion, afterimage); health; posture on both sides; stamina; heal flasks.
- Input buffer (150 ms, paused during hitstop), cancel rules table, hitstop by weight, hit flash, knockback, directional reactions.
- Posture break → deathblow with camera zoom and slow motion (depth of field arrives in M8).
- Lock-on camera with framing of both fighters, collision and damping; camera shake presets with an intensity setting.
- Katana full moveset.
- Sparring automaton: a training construct with one attack per telegraph class, on a schedule.
- First effects: GPU particles v1 (sparks), parry flash with a short-lived point light, ribbon trail v1.
- First sounds, synthesized: clash, parry ring, whoosh, hit.
- Frame data overlay, hitbox and hurtbox view, slow motion 0.25× / 0.5×, invincibility, replay recording and the headless replay runner.
- Unit tests: parry window edges, perfect window edges, i-frames, input buffering, posture math, cancel windows, hitstop timing, perfect-dodge detection.

You test: parry and dodge feel against the automaton; editing `tuning.json` live; overlay readouts.

Exit: timing tests pass and you judge the parry good against the automaton.

### M5 — The five weapons

Deliverables
- Generators for greatsword, twin daggers, spear and kusarigama (chain rendering and chain physics).
- Full movesets through swing specs; abilities Iaido Counter, Earthsplitter (with floor cracks), Blood Dance (bleed stacks), Vaulting Strike, Chain Pull.
- Perfect-parry and perfect-dodge bonuses for all five; swap animation; swap strike; radial menu with slow motion; ability meter.
- Per-weapon trail style and sound profile; stats in `Data/weapons/*.json`.

You test: every move against the automaton with the frame data overlay.

Exit: all five weapons complete and tunable live.

### M6 — Boss framework, attack library, telegraphs

Deliverables
- Hierarchical state machine: approach, circle, step in and out, attack, pressure string, recovery opening, stagger, phase transition, deathblow victim.
- Weighted selection by distance, phase, cooldown and history (no third repeat); a habit model that shifts weights within fixed limits.
- The full attack library from the brief (17 building blocks) as parametric specs.
- Telegraph system: weapon glow shader for white, red, purple and gold; one audio cue per class; colorblind shapes and patterns.
- Phase transition sequences with hooks for lighting, stance and music.
- Boss JSON schema; fairness linter in tests and CI (minimum telegraph lead per tier, gaps inside strings against parry cooldown and dodge recovery, no unavoidable overlaps).
- AI debug overlay, boss select cheat.
- Roster bible: names, titles, weapons and silhouette concepts for all 54 encounters, for your review.

You test: the automaton upgraded into a library-driven sparring boss; the AI overlay.

Exit: a boss defined purely in JSON fights with the full library, and the linter is green.

### M7 — Tier 1: The Outcast Yard (play-test gate)

Deliverables
- Design sheets for the five bosses (name, title, lore line, visuals, weapon, stats, 8–15 attacks, 2–3 phases, signature move, weaknesses), reviewed by you before implementation.
- Five bosses with shortsword, hand axe, club, machete and falchion; the Outcast Yard arena theme.
- Tutorial prompts that teach parry, dodge and telegraph reading.
- Fight flow: intro card, boss HUD, death screen with retry in under 2 s, victory, prep screen, tier progress saved.
- Accessibility options that matter for testing: timing assist, shake intensity, flashing toggle.

**Stop here for a thorough play-test.** Feedback rounds continue until tier 1 feels right, and the lessons go back into the library and linter before any other tier starts.

### M8 — Effects and post-processing

Deliverables
- Bloom (soft-knee threshold, energy-conserving blend), GTAO, SSR, froxel volumetric fog and light shafts, per-object motion blur, depth of field for deathblows and cinematics, chromatic aberration and radial blur on big hits and perfect parries, grain, vignette.
- MetalFX temporal and spatial upscaling toggle; TAA polish.
- Particle emitter library (embers, dust, snow, ash, rain, debris with floor collision), per-weapon trails v2, cloth (capes, banners, robes, scarves), hair chains, emissive runes and eyes.
- All six sky presets with matching lighting.
- Quality presets, per-effect toggles, resolution scale.

Exit: High at 1080p holds 60 FPS on base M1 in the tier 1 arena in benchmark mode.

### M9 — Audio and adaptive music

Deliverables
- Full effects library (footsteps per floor material, cloth, wind, rain, fire), weapon × material layering, HRTF spatialization, per-arena reverb, final telegraph cues.
- Music system: per-tier stems, intensity layering, phase transitions, deathblow drop-out, stingers.
- Volume sliders for master, music, effects and UI; audio debug view.

Exit: tier 1 is fightable by ear (telegraph class and direction are audible).

### M10–M14 — Remaining tiers

Order: M10 tiers 2 + 3, M11 tiers 4 + 5, M12 tiers 6 + 7, M13 tiers 8 + 9, M14 tier 10. Each milestone starts with design sheets for your review, then arena themes, the technology the tier needs, the bosses, and a play-test checkpoint.

| Tier | New technology |
|---|---|
| 2 Iron Garrison | Offensive shields, shield bash, boss guarding |
| 3 Crimson Monastery | Flexible weapons (three-section staff, meteor hammer) on the chain system |
| 4 Drowned Harbor | Weapon grabs (hook blades, harpoon, anchor chain) with player escape; rain and wet floors with SSR |
| 5 Ashen Forge | Giants (large proportions, camera framing for big bosses); molten and fire effects |
| 6 Frost Citadel | Frost wear masks, ice materials, snow |
| 7 Hollow Court | Fast duelists, feints, tighter windows |
| 8 Storm Peaks | Lightning trails and contact bursts, storm sky |
| 9 Eclipse Sanctum | Shadow effects that stay readable, urumi whip-sword |
| 10 Throne of Blades | Mid-fight weapon switching for bosses |

### M15 — Gauntlets and the Blade Sovereign

- Three two-boss gauntlets: attack tokens so the pair coordinates without unreadable overlaps, off-screen attack indicators and audio, lock-on switching, framing for three fighters.
- The Blade Sovereign: four phases, all five player weapons through the shared Fighter core, mirrored abilities.

### M16 — Menus, progression, save, settings, accessibility

- Main menu with the live arena scene; Campaign Rush, Boss Select, Endless Gauntlet (score and personal best), Hard Mode, prep screen.
- Rewards: procedural weapon skins and trails; achievements (no-hit, perfect parries only, and more).
- Stats screen, full remapping UI, subtitles, complete colorblind mode.
- Save system: versioned JSON in `~/Library/Application Support/BladeRush/`, atomic writes, migrations, autosave after every boss.

### M17 — Performance, packaging, polish

- Benchmark every arena and fight; LODs, culling, instancing, memory and load-time audits (under 5 s per arena); a sustained thermal run on a fanless MacBook Air.
- Final `.app`: icon, `Info.plist`, ad-hoc signature, precompiled metallib when available.
- Release checklist and bug bash.

Throughout: benchmark numbers reported at every milestone from M2, tests and linter kept green, this document's status table updated every session.

---

## 6. Parts of the brief that need a realistic alternative

1. **Characters at the level of painted concept art, from code alone.** Realistic target: strong stylized figures with great silhouettes, materials and lighting, with the look of high-end painted figurines for the bodies. What raises the ceiling: design around what procedural geometry does best. Most bosses wear helmets, masks, hoods or veils with glowing eyes (faces are the hardest thing to generate convincingly), and silhouettes come from armor, cloaks, headgear and weapons, which SDF and parametric modeling handle well. Capture sheets let you critique every boss.

2. **About 700 hand-keyed animations as per-bone JSON keyframes, at Sekiro quality.** Realistic target: readable, weighty, well-timed animation with strong anticipation and follow-through. Mocap-fluid motion needs an animator or motion data. The alternative is section 3.5: swing specs, IK, procedural layers and one shared skeleton make attacks tunable data, and every improvement to the solver lifts all attacks at once. JSON keyframes stay available for hand-tuned key poses.

3. **120 FPS on ProMotion at High or Ultra, native resolution.** ProMotion MacBook Pros start at M1 Pro, with native resolutions near 3024×1964, about three times the pixels of 1080p. Realistic target: 120 FPS at Medium with MetalFX upscaling from a ~1080p–1440p internal resolution on Pro and Max chips; newer chips reach High. Resolution scale defaults to an internal resolution near 1080p on every display.

4. **High at 1080p/60 on base M1 with the full effect stack.** Achievable with care: GTAO, SSR and volumetrics at half resolution, cached static shadows, 16-bit render targets. The worst case is the 7-core GPU MacBook Air with thermal throttling in long sessions, so M17 includes a sustained thermal run there. Ultra targets M1 Pro and newer.

5. **Build-time shader compilation.** Section 3.1: runtime compilation is the primary path.

6. **Synthesized choir and strings that sound orchestral.** Realistic target: a dark hybrid score where synthesis sounds intentional (deep drums and taiko-like membranes, drones, metallic percussion, formant choir pads, bowed-string textures from filtered saw stacks). A convincing orchestra from synthesis alone is unlikely.

7. **Boss dialogue with subtitles.** With no audio files, boss voices need a source. Option A (default): text dialogue with subtitles and a stylized vocal texture. Option B: lines spoken by macOS system voices through `AVSpeechSynthesizer` (part of AVFoundation, comparable to system fonts), processed with pitch, distortion and reverb into a boss voice.

8. **Hard Mode with new attacks for all 54 bosses.** This multiplies content. Alternative: each boss gets 1–2 hard-mode attacks derived from its existing specs (extended strings, added feints, delayed variants), plus the global tightening of windows and speed.

9. **Fairness of about 800 attacks checked by hand.** One tester can't cover that repeatedly. Alternative: the fairness linter and headless bot runs are automated gates, and your play-tests focus on feel and fun.

---

## 7. Design gaps to resolve before M4

1. **Block.** Section 6 of the brief says posture "fills when you block", while the controls list has no block input and section 7 describes parry only.
   - **A (recommended):** parry-only as written. "Block" means a normal (non-perfect) parry, and a mistimed parry is punished. Keeps the precision identity. A hold-to-guard can exist as an assist option.
   - **B:** Sekiro model. Hold parry to guard (chip damage and posture), tap on time to parry. Softer; the failed-parry punishment mostly disappears.
2. **Jump.** Low sweeps "must jump or dodge", the spear vaults and the greatsword leaps, and the controls list has no jump. Recommended: add Jump (Space / south face button) without i-frames, so jumping a sweep is a skill with its own reward (a jump counter).
3. **Defaults used unless you decide otherwise** (all tunable):
   - Parry window measured from the press timestamp to the moment a hit connects: 0–60 ms perfect, 60–150 ms normal. When nothing connects within 150 ms: whiff, 200 ms of vulnerability, 350 ms parry cooldown.
   - Perfect dodge: an attack would have hit the player's hurtbox within 100 ms after the dodge started.
   - Perfect-dodge slow motion: the world runs at 0.3× for 0.5 s of real time, the player keeps full speed.
   - Hitstop freezes both fighters; the input buffer and timers pause during hitstop.
   - Deathblow window after a posture break: 2 s, triggered by light attack in range.
   - Every attack belongs to exactly one telegraph class; white is the default parryable class.
   - Timing assist widens parry and dodge windows by up to 100%.

---

## 8. Risk register

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | I can't compile Metal/AppKit code or see the screen | Slow fix loops; visual problems found late | CI on macOS, portable core tested on Linux, capture mode, replays, bug bundles, detailed logs |
| R2 | Procedural characters look blobby or generic | Weakens pillar 2 and boss identity | Hybrid SDF + hard-surface, dual contouring for edges, helmets and masks, silhouette reviews through captures, mesh preview tool |
| R3 | Animation volume and quality | Stiff attacks, weak telegraphs | Swing specs, IK, shared skeleton, animation contact sheets, anticipation rules checked by the linter |
| R4 | Performance on base M1 (68 GB/s bandwidth, 7-core GPU variant, fanless throttling) | Missing 60 FPS on High | Per-pass budgets from M2, half-res effects, cached shadows, 16-bit formats, memoryless targets, MetalFX, presets that really cut cost |
| R5 | Input-to-screen latency with triple buffering | Parries feel late or unfair | Timestamped inputs, late input sampling and drawable acquisition, low latency mode, no frame interpolation |
| R6 | Toolchain variance (Xcode 16 or 26, Command Line Tools only, missing XCTest or Metal toolchain) | Builds fail on your Mac | `doctor.sh`, runtime shader compilation, CI pinned to a known Xcode |
| R7 | Swift performance traps (reference counting in hot loops, copy-on-write, dynamic dispatch, unoptimized builds) | CPU frame-time spikes | Struct-of-arrays and unsafe buffers in hot paths, always-optimized builds, Instruments signposts |
| R8 | Real-time audio safety in Swift | Crackles and dropouts | Offline synthesis; the audio thread only mixes; any live command queue is a lock-free ring buffer in a tiny C target of our own (Swift's `Atomic` needs macOS 15) |
| R9 | `.app` bundling and privacy details: SwiftPM resource bundle layout breaks signing; ad-hoc signatures change every build, so macOS may ask again for Desktop access for screenshots | Broken package, repeated prompts | Own resource locator; screenshots fall back to `~/Library/Application Support/BladeRush/Screenshots` |
| R10 | Chain and flexible weapons (kusarigama, meteor hammer, anchor, chain whip, urumi, three-section staff, flail) | Hits that feel random, hard to read | Hits follow authored guide curves, physics for visuals only, telegraphs on the chain head |
| R11 | Readability against spectacle (bloom, fog, particles, dark skies hiding telegraphs) | Unfair deaths | Telegraph glows composited with guaranteed contrast after tonemapping, particle density limits near fighters, readability check in every capture set and play-test |
| R12 | Camera with giants and two-boss gauntlets | Attacks lost off-screen | Size-aware framing solver, off-screen indicators, directional audio |
| R13 | Content scale and sameness across 54 bosses | Fatigue, weak late tiers | New technology per tier, 1–2 signature mechanics per boss, library improvements fed back, play-test gates |
| R14 | Replay determinism across machines (libm and floating-point differences between Apple Silicon and my x86 container) | Replays diverge off your Mac | Own deterministic trig in simulation code; replays exact on Macs and best-effort elsewhere, with the event log as ground truth |
| R15 | GitHub Actions limits: hosted Mac runners are virtual machines where Metal rendering may be unavailable; macOS minutes cost 10× on private repos; my push may lack permission to add workflow files | Less automation | CI compiles and tests; captures run on your Mac; if the workflow push is refused, I hand you the file |
| R16 | Generation time at load (SDF meshing, textures, audio) | Slow loads and retries | Content-hash disk cache, background generation, retries reuse everything in memory |
| R17 | GPU hangs from a faulty compute shader during development | Freezes, lost repro | `--validate` flag with Metal API and shader validation, bounds-checked debug variants, log flushed every frame |
| R18 | Long project across many ephemeral sessions | Lost context | This document's status table, design sheets and decisions kept in `Docs/`, updated every session |

---

## 9. Performance budget (base M1, 1080p, High — targets until measured)

GPU, out of 16.6 ms:

| Pass | ms |
|---|---|
| Shadows (cached static + dynamic + fighter map) | 1.2 |
| Pre-pass | 0.8 |
| Hi-Z, clustering, contact shadows | 0.4 |
| GTAO (half res) | 0.8 |
| Volumetric fog (froxels) | 1.2 |
| Opaque forward + sky | 3.0 |
| SSR (half res, masked) | 0.8 |
| Particles, trails, transparents | 1.0 |
| TAA / MetalFX | 0.6 |
| Motion blur, DOF, bloom | 1.0 |
| Tonemap, grade, final effects, UI | 0.5 |
| **Total** | **11.3** |

About 5 ms of headroom for spikes and big effect moments.

CPU per 60 Hz frame: simulation (two ticks) 1.0 ms, animation 1.0, cloth 0.6, AI 0.2, render encoding 1.5, audio control 0.2 — about 4.5 ms.

Measured numbers replace these from M2 onward.

---

## 10. Open questions

1. Block: option A or B (section 7)?
2. Jump: add it?
3. Location: `BladeRush/` inside this repository next to Elemental Clash, or a new repository?
4. Hardware and tools: Mac model and chip (GPU core count), display refresh rate, macOS version, full Xcode (which version) or Command Line Tools only, controller model(s).
5. Automation: may I add a GitHub Actions macOS workflow, and is the repository public or private? Can you allow `download.swift.org` in this environment's network settings so I can build and test the portable core here?
6. Boss voices: text only, or processed system voices (section 6, item 7)?
