# Blade Rush

Blade Rush is a native macOS 3D boss-rush action game: one duelist, five weapons, fifty
bosses in ten themed tiers, three gauntlets and a final duel against **The Blade Sovereign**.
It is written in Swift with a custom Metal renderer and uses only Apple frameworks. Every
mesh, texture, sound, song, icon and arena is generated in code, so the repository holds
zero binary assets.

## Requirements

- macOS 14 or later on Apple Silicon (M1 or newer)
- Xcode 15+ command line tools (Swift 5.9+)
- Optional: a game controller (Xbox, PlayStation, MFi)

## Build and run

```bash
Scripts/run.sh            # build (release) and run from the source tree, with hot reload
Scripts/build.sh          # release build of every product
Scripts/package.sh        # build/BladeRush.app: Info.plist, generated icon, ad-hoc signature
Scripts/test.sh           # unit tests, self tests, data validation, shader + app type-checks
```

`Scripts/run.sh` reads `Data/*.json` and `Sources/BladeRush/Shaders/*.metal` from the
repository, so edits to tuning, animations, bosses or shaders apply while the game runs.
The packaged app carries its own copies in `Contents/Resources`.

The headless tool runs anywhere Swift runs (macOS or Linux):

```bash
swift run -c release BladeSim selftest            # combat timing self tests
swift run -c release BladeSim validate            # data consistency report
swift run -c release BladeSim simulate all 90     # bot plays every encounter
swift run -c release BladeSim simulate gorrik 60  # one boss
swift run -c release BladeSim app-smoke           # drives menus -> fight -> victory headless
swift run -c release BladeSim preview-anims       # CPU-rendered pose sheets (preview/)
swift run -c release BladeSim icon out.iconset    # the app icon at every size
```

## Controls

| Action | Keyboard / mouse | Gamepad |
| --- | --- | --- |
| Move | W A S D / arrows | Left stick |
| Camera | Mouse | Right stick |
| Light attack | Left click | RB / R1 |
| Heavy attack (hold to charge) | E / mouse button 5 | RT / R2 |
| Weapon ability | F | LT / L2 |
| Parry (tap) / block (hold) | Right click | LB / L1 |
| Dodge | Space | B / Circle |
| Next weapon (hold: radial menu) | Tab / wheel down | Y / Triangle |
| Previous weapon | Shift+Tab / wheel up | D-pad left |
| Heal | R | X / Square |
| Lock on | Q / middle click | R3 |
| Pause | Esc | Menu |

Every gameplay action can be rebound in Settings → Controls (keyboard, mouse and gamepad).

### Reading the bosses

Attack telegraphs use one color language, each with its own sound cue:

- **White**: parryable. Parry for posture damage; a perfect parry is a larger window at the start.
- **Red**: unblockable. Dodge it.
- **Purple**: delayed or feint. Wait for the real swing.
- **Gold**: combo ender. The punish window follows it.

Break the boss's posture meter to open a deathblow.

## Debug tools

| Key | Alternative | Tool |
| --- | --- | --- |
| F1 or ` | Ctrl+1 | Overlay: FPS, frame time, CPU sections, GPU time per pass, draw calls, triangles |
| F2 | Ctrl+2 | Hitboxes and hurtboxes |
| F3 | Ctrl+3 | Frame data (startup / active / recovery, windows) |
| F4 | Ctrl+4 | Boss AI (state, weights, habit tracking) |
| F5 | Ctrl+5 | Free camera (WASD, mouse, Space / Ctrl) |
| F6 | Ctrl+6 | Invincibility |
| F7 | Ctrl+7 | Slow motion (1×, 0.5×, 0.25×) |
| F8 | Ctrl+8 | Unlock every boss in Boss Select |
| F9 | Ctrl+9 | Reload all data files |
| F10 | Ctrl+0 | Dump the fight state to the log |
| F11 | Ctrl+K | Kill the current boss |
| F12 | Ctrl+S | Screenshot to the Desktop (PNG) |

## Files on disk

Everything lives in `~/Library/Application Support/BladeRush/`:

- `save.json`: progress, unlocks, statistics (autosaved after every fight)
- `settings.json`: graphics, audio, accessibility, bindings
- `Logs/bladerush.log`: the session log (shader errors, load timings, state dumps)
- `Cache/`: generated noise textures (safe to delete)

Set `BLADERUSH_HOME` to use a different folder, `BLADERUSH_DATA` / `BLADERUSH_SHADERS` to
point at other data or shader directories.

## Game content

- **Weapons**: Katana (Iaido Counter), Greatsword (Earthsplitter), Twin Daggers (Blood
  Dance), Spear (Vaulting Strike), Kusarigama (Chain Pull). Each has its own moveset,
  stance, ability and stat profile; the player switches between them mid-fight.
- **Tiers**: The Outcast Yard, The Iron Garrison, The Crimson Monastery, The Drowned
  Harbor, The Ashen Forge, The Frost Citadel, The Hollow Court, The Storm Peaks, The
  Eclipse Sanctum and The Throne of Blades, five bosses each. Then three gauntlets and The
  Sovereign's Void. Bosses fight only with melee weapons and their bodies.
- **Modes**: Campaign Rush, Boss Select, Endless Gauntlet and Hard Mode (tighter windows,
  faster bosses, extra attacks). Instant retry, weapon prep screen, skins and trails from
  achievements, lifetime statistics.
- **Accessibility**: timing assist, camera shake scale, flashing reduction, colorblind
  telegraph shapes, subtitles, remapping, sensitivity and invert-Y.

## Architecture

```
Sources/BladeCore     portable game code (macOS + Linux), unit-tested headless
  Math/               vectors, matrices, quaternions, noise, swept capsule geometry
  Combat/             timing tuning, defense resolver, posture, stamina, input buffer, strikes
  Animation/          22-bone skeleton, IK rig (two-bone arms/legs, grips), JSON anim library
  Procedural/         SDF characters -> Surface Nets meshes, weapons, arenas, textures, icon
  Physics/            Verlet cloth and chains
  Game/               world (240 Hz fixed step), player, boss HSM + adaptive AI, camera, FX,
                      modes, save, settings, content cache
  Audio/              DSP, synthesized sound bank, mixer, adaptive music
  UI/                 menus, HUD and overlays as draw lists
  Render/             RenderFrame (what to draw), scene builder, render math, CPU preview
Sources/BladeRush     the macOS app
  App/                NSApplication, window, MTKView, main loop
  Platform/           keyboard/mouse/gamepad input, AVAudioEngine output
  Render/             Metal renderer, runtime shader library, SDF font atlas
  Shaders/            Metal shading language sources (compiled at runtime)
Sources/BladeSim      headless simulator / validator / preview tool
Tests/BladeCoreTests  XCTest suites
Data/                 tuning, weapons, attacks, bosses, arenas, animations (JSON, hot reload)
Scripts/              build, run, package, test, boss data generator, type-check tooling
```

### Technical choices

- **Simulation**: combat runs at a fixed 240 Hz. Input events carry sub-frame timestamps, so
  parry and dodge windows are measured when the key went down, independent of the display
  rate. Every window, hitstop, stamina cost and camera constant lives in `Data/tuning.json`.
- **Characters**: bodies are signed distance fields (smooth-union primitives with clip
  planes) polygonized by Surface Nets. Skin weights come from primitive ownership, and cavity
  AO plus edge wear are baked from the field. Animation is procedural: key poses in JSON drive
  an IK rig whose strike tracks are synchronized with frame data.
- **Renderer**: Forward+ with a depth/normal/velocity prepass and compute light culling in
  16×16 tiles, three-cascade shadow maps with PCF and contact shadows, spherical harmonics
  plus a baked sky cubemap for image-based lighting, and triplanar procedural PBR materials.
  Post-processing covers SSAO, SSR, volumetric fog with light shafts, TAA or MetalFX temporal
  upscaling, bloom, depth of field, motion blur, ACES tonemapping, color grading, chromatic
  aberration, radial blur, film grain, vignette and letterbox. It also draws GPU particles,
  weapon trails, projected decals and afterimages.
- **Shaders** are compiled at runtime, one library per file with `Common.metal` prepended.
  A broken effect disables only its own pass (the log names the error) and files hot-reload.
- **Audio**: every sound is synthesized at startup (modal synthesis, Karplus-Strong, filtered
  noise), mixed with spatial panning and reverb; the music engine composes per-arena
  layers that follow fight intensity and boss phases.

## Testing

`Scripts/test.sh` runs the full chain:

1. `swift test`: combat timing (parry/perfect windows, dodge i-frames, input buffer, hitstop,
   posture, swept hitboxes), data validation, a scripted headless fight, and render math
   (TAA jitter, cascade fitting, frustum culling).
2. `BladeSim selftest`, `validate` and a bot simulation.
3. `Scripts/mslcheck/check_msl.py`: type-checks every `.metal` file with clang through a
   Metal standard library shim (vector constructor arity, members, types).
4. On Linux, `Scripts/maccheck/check_mac.sh`: type-checks the macOS target against stub
   modules of the Apple frameworks.

## Status and known risks

The game code in `BladeCore` is compiled, unit-tested and exercised end to end by the headless
simulator: all 54 encounters run to completion without errors or invalid values. The macOS layer (renderer, shaders,
input, audio output, window) was written in a Linux environment without the macOS SDK. It
passes the shader and API-stub type-checks above, and it has yet to be compiled with Xcode or
run on a Mac. Expect a first build on macOS to surface a handful of small API or shader
fixes. These are the areas to watch:

- **Shader compile errors** appear in the log and disable only the affected pass. The game
  keeps running, so check `Logs/bladerush.log` first.
- **MetalFX** assumes the pixel-space jitter convention; if the upscaled image shimmers, flip
  the sign of `jitterOffsetX/Y` in `Renderer.swift`. TAA is the default upscaler.
- **Performance** targets (60 FPS at 1080p High on M1, 120 FPS with ProMotion) are designed
  for and still unmeasured. The quality presets and the resolution scale are the first knobs.
- **Face winding** is counter-clockwise (verified by the CPU preview renderer). If meshes
  render inside-out, change `setFrontFacing` in `Renderer.swift`.

What to try first on a Mac: `Scripts/test.sh`, then `Scripts/run.sh`. Open the overlay with
F1 and fight Gorrik in the Outcast Yard (Campaign Rush, tier I).
