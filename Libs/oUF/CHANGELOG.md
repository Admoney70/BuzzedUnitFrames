**Vendored build: oUF 14.0.0**

PRISTINE UPSTREAM COPY — NO LOCAL CODE PATCHES, INCLUDING `oUF.xml`.
(Owner decision, v65: oUF is a shared library; with X-oUF metadata it can
register globally and another addon's copy could win the LibStub race, so this
copy must never diverge from upstream. When updating: copy upstream verbatim,
nothing to re-apply.)

**This is now literally true.** It was not before v67 — the previous vendored
build patched `oUF.xml` to load a BuzzardFrames-authored element
(`elements/auras_legacy_1207.lua`) and retained three elements upstream had
already removed. `diff -r` against the upstream release now reports no
differences.

---

## Salvaged elements — live in `UnitFrames/oUFElements/`, NOT here

oUF 14.0.0 removed three elements. Two of them BuzzardFrames still wires, so
they were vendored into the addon's own folder and are loaded from
`BuzzardFrames.toc` immediately after `Libs\oUF\oUF.xml`:

| Element | Upstream status | Why we keep it |
|---|---|---|
| `healthprediction.lua` | removed in 14.0.0 (changelog #43) | `UnitFrames/oUF_Absorbs.lua` wires `frame.HealthPrediction`; without the element that table is inert and all heal-prediction / damage-absorb / overshield art silently vanishes |
| `pingindicator.lua` | absent from 14.0.0 | `UnitFrames/oUF_Shared.lua` wires `self.PingIndicator`, exposed as `oufShowPingIndicator` (default ON) |
| `powerprediction.lua` | removed in 14.0.0 (changelog #33) | **dropped** — zero references in BuzzardFrames |

This works because both files use only oUF's **public extension API** —
`local _, ns = ...; local oUF = ns.oUF` then `oUF:AddElement(...)`. `ns` is the
addon namespace every BuzzardFrames file receives, and `ns.oUF` is populated by
the library's `init.lua`, so any file loaded after `oUF.xml` can register an
element. Nothing in them reaches into library internals.

Both were checked against 14.0.0's "keep state internal" sweep: they touch only
`self.Health` (still a StatusBar), `self.__unit` and `element.__owner` (both
unchanged in 14.0.0), StatusBar methods, and `element.values`, which
`healthprediction` creates itself. Neither reads `Health.cur`/`Health.max`,
`SetColorDisconnected`, or `__isHoriz`/`__size`.

Upstream's replacement for HealthPrediction is a set of Health sub-widgets
(`Health.HealingAll`, `Health.DamageAbsorb`, `Health.HealAbsorb`, plus
`HealingPlayer`/`HealingOther` and three Over* indicators — note the
capitalisation changed). Migrating `oUF_Absorbs.lua` onto those would let the
salvaged file go; until then, keeping it is the smaller and safer option.

---

## BuzzardFrames-side shims (kept OUT of the library)

These live in `UnitFrames/oUF_Shared.lua`:

- `oUF.DisableBlizzard` wrapper: per-frame hide-Blizzard profile gating.
- `oUF:Spawn` wrapper: re-parents spawned frames to `UIParent` and applies
  `SetRolesets`. **Now redundant** — 14.0.0 deleted `PetBattleFrameHider`,
  parents to `UIParent` itself, and applies the same
  `arenaFrames`/`unitFrames` rolesets with the same `unit:match('arena%d?')`
  split. Safe to delete; harmless to keep (a no-op re-parent plus a duplicate
  `SetRolesets` call).

BuzzardFrames does not use the library's `PrivateAuras` element; its own
private-aura dispel overlay is `Auras/PrivateAuraDispelOverlay.lua`.

---

## Migration status

See `Docs/oUF_14.0.0_Migration_Plan.md`. The 14.0.0 upgrade has known breaks in
`oUF_Castbar.lua` (`element.notInterruptible` and `holdTime` moved into a
private `STATE` table; `CustomTimeText` removed) and `oUF_ResourceBar.lua` /
`oUF_Shared.lua` (ClassPower `PostUpdate` gained `hasCurChanged` at position 3;
`__isEnabled`/`__cur`/`__max`/`__powerType` internalised). Those are Phase B2 of
that plan and are NOT fixed by the swap alone.
