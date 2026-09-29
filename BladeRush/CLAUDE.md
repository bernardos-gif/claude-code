# Blade Rush — notes for Claude sessions

Read `Docs/DesignBrief.md` (the owner's brief, source of truth) and `Docs/DevelopmentPlan.md` (plan, decisions, milestone status) before working here.

Rules from the brief:
- Swift + Metal with Apple frameworks only. No third-party packages, no asset files: every mesh, texture, animation, effect and sound is generated in code. System fonts are allowed.
- Tuning values and content live in `Data/*.json` with hot reload.
- One milestone at a time. After each one: exact build/run commands, what to test, then wait for the owner's feedback. Commit per milestone.
- If something in the brief is technically unrealistic, say so directly and propose the best alternative.

Project rules:
- `Sources/BladeCore` stays free of Apple-only imports so it compiles and tests on Linux.
- The cloud container is Linux: Metal and AppKit code can't be built there. Verify through CI (macOS runner) and the owner's Mac.
- Update the status table in `Docs/DevelopmentPlan.md` at the end of every session.
- The repository root is a separate project (Elemental Clash, Three.js). Leave it untouched.
