# SquizzTalents

A talent loadout manager for World of Warcraft Retail, built for patch 12.1.

All your talent loadouts and saved builds in one list, one click to apply any of them, and a
reminder when your build doesn't match the content you just entered.

**[Download on CurseForge](https://www.curseforge.com/projects/1705647)** ·
[Changelog](CHANGELOG.txt)

---

## Features

**Loadouts**
- One list of your Blizzard loadouts and your own saved builds. Your own builds are stored as
  talent codes, so there is no limit on how many you keep
- Click a build to apply it. The game confirms the result, and anything that could not be applied
  is reported. Applying is refused, with the reason shown, in combat, during a Mythic+ key, or
  whenever the game says talents cannot be changed
- Save your current build, and right-click any build to apply, rename, tag, pick an icon, export
  or delete it
- Import and export Blizzard's own talent codes, the same ones build sites use
- A searchable icon picker: talents, spells, your specs, this season's dungeons, or the full icon
  list
- Builds from an older talent tree are marked Outdated, with one click to refresh or remove them
- Opens right beside Blizzard's talent window, or on its own with `/sqt`

**Reminders**
- On entering a dungeon, raid, delve, battleground or arena, on slotting a keystone, and on a
  ready check — only when your active build isn't the one you chose for that content
- Choose builds for one difficulty of an instance, a whole instance, or every dungeon, raid,
  delve, battleground or arena. The most specific choice wins
- Never interrupts an active key, and waits for combat to end

No libraries and no combat data: everything works on your own talent data, out of combat.

## Installing

Install from [CurseForge](https://www.curseforge.com/projects/1705647), or
manually: download this repository and drop the `SquizzTalents` folder into

```
World of Warcraft\_retail_\Interface\AddOns\
```

Requires WoW Retail 12.1 (interface 120100). Nothing else to install.

## Commands

| Command | What it does |
|---------|--------------|
| `/sqt` or `/squizztalents` | Open the loadout window |
| `/sqt save [name]` | Save your current build |
| `/sqt import` | Import a talent code |
| `/sqt config` | Settings |
| `/sqt notes` | Show this version's release notes again |
| `/sqt remind` | Run the reminder check now |
| `/sqt debug` | Copyable diagnostic report — please include it with bug reports |

## Bugs and requests

Please open an [issue](../../issues). For a reminder that fires when it shouldn't (or doesn't
when it should), the `/sqt debug` report is the most useful thing you can include.

## Support

If you enjoy using SquizzTalents, consider supporting development on
[Ko-fi](https://ko-fi.com/squizz) ❤️

## More addons by Squizz

- **[SquizzFrames](https://www.curseforge.com/projects/1649203)** — party, raid, pet and unit frames with a full indicator system, click-casting and a tank tracker
- **[Squizzumables](https://www.curseforge.com/projects/1483099)** — one-click reminders for food, flasks, oils and class buffs, plus raid tools and a restyled Cooldown Manager
- **[Squizzcap](https://www.curseforge.com/projects/1713974)** — what killed you, how hard it hit and how fast you went down, with every death of a key saved to look back on
- **[DPS Report](https://www.curseforge.com/projects/1504877)** — a lightweight damage meter with spell breakdowns and an end-of-key MVP summary
- **[Avatar Continued](https://www.curseforge.com/projects/1533608)** — your character model on screen as part of your UI
- **[KSLBestDungeon](https://www.curseforge.com/projects/1599575)** — ranks Mythic+ dungeons by how many of your KeystoneLoot favorites drop there

## License

[MIT](LICENSE).
