# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

**SquizzTalents** is a World of Warcraft retail (12.1, Midnight) talent loadout
manager with content-aware reminders. It lists the player's Blizzard loadouts and
their own saved builds in one place, applies any of them with one click, and pops
a reminder on entering content when the active build isn't the one chosen for it.

- Folder / TOC / SavedVariable: `SquizzTalents` / `SquizzTalents.toc` / `SquizzTalentsDB`
- Slash: `/sqt` and `/squizztalents`
- Repo: https://github.com/SquizzCheeze/SquizzTalents — CurseForge project **1705647**
- **No libraries at all.** Keep it that way unless the user agrees to one (the
  original brief said "ask before adding dependencies").
- Built from scratch on 2026-09-21 and shipped as V1.0 the same day. The 0.x
  versions were development builds and never shipped.

## Hard constraints (from the original brief — still binding)

- **No combat data, ever.** Everything runs out of combat on the player's own,
  non-secret talent data. Never register `COMBAT_LOG_EVENT(_UNFILTERED)`.
- **No heavy hooks on Blizzard frames**, no reparenting Blizzard aura buttons, no
  global overrides; `hooksecurefunc` only for post-hooks. Our UI is our own frames.
  This rule is why a Blizzard loadout deleted from our UI can linger in Blizzard's
  talent window until `/reload` (see below) — we deliberately don't poke their frame.
- `issecretvalue` guards (`ns.IsPlain`) on anything that could be secret.
- Frame work that must not happen in combat is queued with `ns.RunOutOfCombat`
  (flushes on `PLAYER_REGEN_ENABLED`).
- Namespace table only (`local _, ns = ...`). The only globals are the
  SavedVariable, the `SLASH_`/`SlashCmdList` entries, `StaticPopupDialogs` entries,
  named frames that `UISpecialFrames` needs for Escape-to-close, and the shared
  `SquizzNotesQueue` (see Welcome).
- **Verify API signatures before using them** against Blizzard's source,
  `Gethe/wow-ui-source` (check the branch: `live` is 12.1.0; `ptr`/`ptr2` are other
  patches), plus the generated docs in `Blizzard_APIDocumentationGenerated`. List
  anything unverified for the user to test in game. warcraft.wiki.gg blocks curl;
  use WebFetch for it.

## Architecture

Load order (`SquizzTalents.toc`):

| File | Role |
|---|---|
| `Locales.lua` | `ns.L`, key = enUS string, missing keys fall back to the key |
| `Style.lua` | `ns.Style`: SquizzFrames' look, copied (not called) — see Theming |
| `Core.lua` | `ns.On(event, fn)` event bus (many listeners per event), `ns.RunOutOfCombat`, `ns.IsPlain`, `ns.Print`, slash commands |
| `Store.lua` | SavedVariables, schema + migrations, settings, own builds, Blizzard metadata, content mappings |
| `Sources.lua` | The two loadout adapters behind one normalized entry shape; spec helpers |
| `Apply.lua` | Applying a build, import-string decoding, stale (outdated) detection |
| `Reminder.lua` | Content detection, mapping lookup, mismatch test, the triggers |
| `UI.lua` | Main window, reminder popup, right-click menu, StaticPopups |
| `ImportExport.lua` | `ns.Transfer`: paste/validate/import a talent code, export a build's code |
| `IconPicker.lua` | Searchable icon grid |
| `Settings.lua` | Canvas page under Options > AddOns (toggles + mapping list) |
| `Welcome.lua` | First-run greeting and per-version release notes |
| `Debug.lua` | `/sqt debug` copyable dump |

Files talk through `ns.*` tables only. `ns.On` registers are in file load order,
so `ADDON_LOADED` runs `Store.Init` (Core) before `Settings` builds its panel.

### Normalized entry

```lua
{ id = "blizz:<configID>" | "own:<n>", source = "blizz"|"own", name, icon, specID,
  tags, configID?, ownID?, importString? }
```

`Sources.Annotate(list)` adds `importStringResolved`, `isActive` (export string ==
active build's), `duplicateOf`/`duplicateName` (own build identical to a Blizzard
loadout) and `staleReason` (own builds only). Everything that compares builds
compares **export strings**.

- **Blizzard loadouts are read live** (`C_ClassTalents.GetConfigIDsBySpecID` +
  `C_Traits.GetConfigInfo`) and never copied. Only our metadata (tags, icon) is
  stored, per character, keyed by configID, and pruned on
  `TRAIT_CONFIG_LIST_UPDATED`/`TRAIT_CONFIG_DELETED` (only when the lists are
  populated — they can be empty for a moment at login).
- **Own builds** are standard talent import strings (`C_Traits.GenerateImportString`
  on the active config), account-wide, filtered to the current spec for display.

### SavedVariables (schema 1)

```lua
SquizzTalentsDB = {
  schema = 1, nextOwnID, lastSeenVersion,
  own      = { [n] = { name, icon, specID, tags, importString, created, updated? } },
  chars    = { ["Name-Realm"] = {
      blizzMeta = { [configID] = { tags, icon } },
      mappings  = { [specID] = { [contextKey] = { entryID, label } } } } },
  settings = { remindOnEnter, remindOnKeystone, remindOnReadyCheck, remindUnmapped },
}
```

Mappings are **per character AND spec** because a `blizz:<configID>` id only means
something to the character that owns it. Add schema changes as a `MIGRATIONS[n]`
step in `Store.lua` and bump `Store.SCHEMA`; new optional fields can just fill
lazily (as `mappings` did) without a bump. A build's icon is a fileID, a texture
path, or `"atlas:<name>"`.

### Applying (Apply.lua)

- **Blizzard entry:** `C_ClassTalents.LoadConfig(configID, true)` — the call
  Blizzard's own loadout dropdown makes — then `UpdateLastSelectedSavedConfigID`
  so their dropdown shows it.
- **Own entry:** decode the import string exactly as Blizzard's
  `ClassTalentImportExportMixin` does (`Blizzard_ClassTalentImportExport.lua`),
  `C_Traits.ResetTree`, then stage with `SetSelection` (choice and hero
  `SubTreeSelection` nodes) and `PurchaseRank`, top of tree first, repeating passes
  until nothing moves (gates and edges unlock as earlier nodes land), then
  `C_ClassTalents.CommitConfig(nil)`. **Do not switch this to
  `C_ClassTalents.ImportLoadout`**: that creates a new Blizzard loadout and eats the
  very cap own builds exist to avoid. `ImportLoadout` is used only for the
  deliberate "Create Blizzard loadout" import.
- Anything that couldn't be staged is committed anyway and reported as `partial`
  with the node IDs.
- **`TRAIT_CONFIG_UPDATED` is a synchronous event** and can fire *inside* the commit
  call. Arm the wait (`BeginWait`) **before** `LoadConfig`/`CommitConfig`, never
  after, or a fast commit is missed and times out as "unconfirmed". Success =
  `TRAIT_CONFIG_UPDATED` for the active or saved configID; failure =
  `CONFIG_COMMIT_FAILED`; 20s timeout = `unconfirmed`, never a false success.
- `Apply.BlockReason()` is the single "can we apply now" answer: combat, active
  key, pending apply, `C_ClassTalents.CanEditTalents()` (Blizzard's own reason
  text). Starter Build active refuses own builds.
- **Blizzard's decoder does no validation.** `ExportUtil.MakeImportDataStream` on a
  character outside the base64 alphabet, or `ExtractValue` past the end, yields a
  `nil` that throws later. `ReadContent` errors cleanly on truncation and callers
  `pcall` it; `Transfer.Parse` checks the alphabet first.
- **Outdated detection** (`Apply.StaleReason`) reads only the 26-byte header:
  serialization version vs `C_Traits.GetLoadoutSerializationVersion()` and the
  128-bit tree hash vs `C_Traits.GetTreeHash`. An all-zero hash (third-party
  sites) skips the check, as Blizzard's importer does. Blizzard loadouts are never
  marked outdated — their window validates its own.

### Reminders (Reminder.lua)

- **Context** from `GetInstanceInfo`: `party` → dungeon, `raid`, `pvp`, `arena`,
  and `scenario` + (`C_PartyInfo.IsDelveInProgress()` or difficulty 208) → delve.
  Keys, most specific first: `i:<instanceID>:d:<difficultyID>`, `i:<instanceID>`,
  `t:<kind>`.
- Popup only on a **mismatch** (the mapped build's export string ≠ active), never
  during an active key, queued until combat ends and re-evaluated then. Unmapped
  content prompts only with `remindUnmapped` on. "Not now" silences only the
  `enter` trigger for that context, for the session.
- **The entry trigger is event-driven as well as timed. Keep it that way.**
  Instance info arrives late with no fixed deadline: a delve read as open world 3s
  in, and then *still* at 15s, because the game only reports it once the delve's
  scenario starts. So `CheckEntry` runs at 3/8/15s after `PLAYER_ENTERING_WORLD`
  AND on `ZONE_CHANGED_NEW_AREA`, `SCENARIO_UPDATE`, `ACTIVE_DELVE_DATA_UPDATE`
  (debounced 1s). `decidedKey` makes it one decision per content per entry; a new
  load or leaving relevant content clears it.
- `Reminder.Check(trigger, label)`: `trigger` drives behaviour (only `"enter"`
  honours Not now); `label` is only for `/sqt debug`. Merging them once made
  "enter #2" silently bypass Not now.

### Import / export (ImportExport.lua)

`Transfer.Parse` validates as the user types: alphabet, header, format version,
spec belongs to the player's class, tree hash, full decode. "Save to SquizzTalents"
works for any spec of the class; "Create Blizzard loadout" requires the current
spec and `C_ClassTalents.CanCreateNewConfig()`, and builds the
`ImportLoadoutEntryInfo` list exactly like Blizzard's
`ConvertToImportLoadoutEntryInfo` (including tiered nodes). Export uses the stored
string for own builds and `GenerateImportString(configID)` for Blizzard ones.

### Icon picker (IconPicker.lua)

The game exposes no icon names, so search covers what *is* named: class talents
(all specs, via `GetEntryInfo`→`GetDefinitionInfo`) and the spellbook by spell
name; specs and this season's M+ dungeons (`C_ChallengeMode.GetMapTable` /
`GetMapUIInfo`, live, no per-season list); and the full macro catalogue
(`GetLooseMacroIcons`/`GetLooseMacroItemIcons`/`GetMacroIcons`/`GetMacroItemIcons`,
mirroring Blizzard's `IconDataProvider`), searchable by number or by file name
where the client returns one. **Hero specs have no spell** — their choice entries
carry a `subTreeID` and their icon is an atlas (`TraitSubTreeInfo.iconElementID`),
stored as `"atlas:<name>"` and drawn with `Style.SetIcon`. Talent Loadouts Ex
(installed alongside) was the reference; its name search comes from the optional
LargerMacroIconSelection addon, which we don't depend on.

### Theming (Style.lua)

Copies SquizzFrames' options look (its `Modules/Options/Widgets.lua` and
`OptionsFrame.lua`): dark flat panels with a black 1px border, a 26px title bar
with a class-colour accent line and a red X, flat buttons filling with the accent
on hover, class-colour toggles and highlights. **Self-contained on purpose** — it
must not require SquizzFrames. Use `S.Window`, `S.Button`, `S.Toggle`,
`S.EditBox`, `S.Highlight`, `S.SetIcon`; don't reintroduce `UIPanelButtonTemplate`
and friends. A `S.Button` tooltip goes in `button.tooltipFunc`, **not** an
`OnEnter` script (that would replace the hover colour). Still Blizzard-styled, by
choice for now: `WowStyle1DropdownTemplate` dropdowns, `MenuUtil` context menus,
StaticPopups. Semantic colours stay: gold = Suggested, red = Outdated, blue =
Blizzard loadout; Active uses the accent.

### Blizzard's talent window caches its loadout list

It only re-reads loadouts on events received **while open** (not on show), so a
Blizzard loadout deleted from our UI while their window is closed keeps showing
there until `/reload`. The delete itself works (confirmed). We print a note rather
than touching their frame.

## Development workflow

No build step and no test suite: edit, `/reload` (enough for Lua), test in game.
`/sqt debug` is the diagnostic: it prints the active build, the instance info,
the matched context and mapping, the last reminder decision **with what
GetInstanceInfo reported at that moment**, settings, the normalized list with
stale reasons, mappings, and the last apply result. Ask the user for it first on
any reminder or apply report.

Dev helpers: `/sqt remind` (run the reminder check now, print why not),
`/sqt testoutdated` (save a copy of the current build with one character of its
tree hash changed, to exercise Outdated / Update / Delete outdated).

### Static checks

- **wowlua_ls** is the real gate (WoW API stubbed):
  `"$HOME/.vscode/extensions/tradeskillmaster.wowlua-ls-<ver>/server/win32-x64/wowlua_ls.exe" check "C:/World of Warcraft/_retail_/Interface/AddOns/SquizzTalents"` —
  baseline is **"No issues found"**; keep it there.
- **luacheck is NOT installed** on this machine (no Lua, no luarocks). `.luacheckrc`
  is maintained anyway: add any new WoW global the code reads to `read_globals`,
  and any it writes to `globals`. Max line length 120.
- Squizzumables' `.claude/check-strings.pl`, `check-backslashes.pl` and
  `check-balance.awk` work on these files (quote the paths; run the awk **one file
  per invocation**).
- **Never write backslash-containing text through sed/perl/awk.** Use Edit/Write.
  Font paths and `Interface\\...` strings get mangled, and a Windows `$TEMP` passed
  to `awk -v` has its backslashes eaten as escapes (this silently corrupted a
  DPSReport file on 2026-09-21 before being caught).

## Releasing

Tag-driven, the same pipeline as SquizzFrames: pushing a `v*` tag runs
`.github/workflows/release.yml` (BigWigsMods/packager), which uploads to CurseForge
(project ID from `## X-Curse-Project-ID`) and creates the GitHub release. Pushes to
`main` publish nothing. The `CF_API_TOKEN` secret is on this repo; the dry run from
the Actions tab shows `CurseForge ID: 1705647 [token set]`.

1. Keep the top `CHANGELOG.txt` section **open (undated)** while work lands.
   `.pkgmeta` sends the whole file as the release notes (SquizzFrames' convention,
   not DPSReport's one-section-plus-archive).
2. Add `RELEASE_NOTES["<version>"]` in `Welcome.lua` — a few player-facing lines,
   not the changelog.
3. When the user says ship: date the heading, bump `## Version:` in the TOC, commit.
4. **Ask before tagging, every time.** Then
   `git tag -a vX.Y -m "VX.Y"` and `git push origin vX.Y`. Annotated tags only —
   the packager ignores lightweight ones.

`## Interface: 120100, 120105` (12.1.0 live and 12.1.5). 12.1.5 is declared but
untested; nothing here touches the APIs 12.1.5 changes (aura containers, damage
meter).

`.pkgmeta` excludes `.github`, `.luacheckrc`, `CLAUDE.md`, `README.md` and other dev
files from the zip; `LICENSE` (MIT, same text as the other Squizz addons) and
`CHANGELOG.txt` ship.

## Welcome / release notes

Ported from SquizzFrames' `Modules/Welcome/Welcome.lua`. The `SquizzNotesQueue`
block is **shared with SquizzFrames, Squizzumables and Avatar Continued** through
`_G` and must stay byte-identical to their copies — it is an interface between the
addons (notes from several addons updating at once queue instead of overlapping).
`ns.hadSavedVariables` is taken at the top of `Store.Init`, before the SavedVariable
table is created: it's the only way to tell a new install from an upgrade out of a
version that predates `lastSeenVersion`.

## Open ideas (not started)

- **Tags** are stored and shown in tooltips but do nothing else; the user chose to
  leave them for later (filtering or search were the options discussed).
- Restyle the dropdowns and StaticPopups to match SquizzFrames.
- Raid boss icons in the picker (the Encounter Journal only gives wide portraits;
  Talent Loadouts Ex hardcodes per-season fileIDs).
- Per-boss mappings (would need to know the next boss before the pull, without
  combat data).
