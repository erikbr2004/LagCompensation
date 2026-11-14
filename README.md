# LagCompensation for SWAT 4

Server-side lag compensation for **SWAT 4 (base game, v1.1)** multiplayer.
Players do **not** need to install anything: unmodified clients can join a server
running this mod.

Version **1.0.1**

---

## What it does

In stock SWAT 4 the server decides whether a bullet hits using the target's
**current** position. A player with high ping sees everyone slightly in the past,
so a shot that was on target on their screen can miss on the server.

This mod makes the server evaluate each shot fired by a remote player at the
moment that player actually saw it:

```
shot time = now - (round trip time + one server frame)
```

The idea is the same as the lag compensation used in Counter-Strike and other
modern shooters: if the target was under the crosshair on the shooter's screen,
the hit is registered.

## How it works

1. `LagCompensationManager` (package `LagCompensation`, server only) records the
   position of every player about 100 times per second (64 samples per player).
2. The weapon base classes `SwatEquipment.ClipBasedWeapon` and
   `SwatEquipment.RoundBasedWeapon` route `BallisticFire()` through a small hook,
   `SwatEquipment.LagCompensationHook`.
3. For every target that moved since the shot time, the bullet ray is shifted by
   the target's displacement and traced against the target's current body. This
   is equivalent to shooting at the past position, but **no actor is ever
   moved**, so there are no side effects on physics, volumes or triggers.
4. The world is still traced with the original ray, so walls keep blocking
   bullets and penetration keeps working.
5. All impacts are sorted along the original ray and handed to the stock
   `FiredWeapon.HandleBallisticImpact()`. Damage, armor, helmets, penetration and
   effects are exactly the game's own.

When the hook is not present (clients, standalone games, servers without the
mod), the stock `BallisticFire()` runs unchanged.

## Why unmodified clients can still join

| Concern | How it is handled |
|---|---|
| Package version mismatch | `LagCompensation.u` is flagged `ServerSideOnly` and is **not** in `ServerPackages`, so it is never sent to clients. |
| Modified `SwatEquipment.u` | Rebuilt with UCC's conform step against the retail file (`SystemConform`). It keeps the **same GUID** as the original (`0c9771cf-bbfb-4180-b351-c7454103666f`); the new code is appended as generation 2, which older clients ignore. |
| Config MD5 anti-cheat ("unexpected number of configuration files") | No new `.ini` file is created. Settings live in `Swat4DedicatedServer.ini` / `Swat4.ini`, which the game excludes from that check (Admin Mod uses the same approach). |
| Server browser | `Version.ini` is untouched (`ModName=SWAT 4`), so the server is listed for everyone. |

## Requirements

- SWAT 4 base game, v1.1 (`Content\System`). The Stetchkov Syndicate expansion
  is **not** supported.
- The server's retail `Content\System\SwatEquipment.u` must be the same file the
  mod was conformed against:
  - size: 361,062 bytes
  - SHA1: `CBA6AC8E063A9EEEDC8C1D1AB90B239712D62EF7`

  Check it with:
  ```
  certutil -hashfile "Content\System\SwatEquipment.u" SHA1
  ```
  If it differs, rebuild the mod using your own retail file (see
  [Building from source](#building-from-source)).

## Installation

### Option A - run from the mod folder (recommended)

1. Create a `LagCompensation` folder inside your SWAT 4 folder, next to
   `Content`, and put the `.bat` files from the release in it.
2. Create `LagCompensation\System\` and copy into it all `*.ini`, `*.int` and
   `shaders.spk` from your `Content\System`, plus `LagCompensation.u` and
   `SwatEquipment.u` from the release.
3. In `LagCompensation\System\Startup.ini`, set (one line):

   ```ini
   FilePath=..\System;..\Content\Scenarios;..\Content\Maps;..\..\Content\System;..\..\Content\Scenarios;..\..\Content\Maps;..\..\Content\Test\Maps
   ```

   so the mod's packages are found before the retail ones.
4. Apply the two changes from [Server configuration](#server-configuration) to
   `LagCompensation\System\Swat4DedicatedServer.ini`.
5. Start the server with `LaunchLagCompensationServer.bat`
   (or `LaunchLagCompensation.bat` to host a non-dedicated server).

No retail file is touched.

### Option B - install into `Content\System` (e.g. game hosting)

1. Back up `Content\System\SwatEquipment.u`.
2. Copy `SwatEquipment.u` and `LagCompensation.u` into `Content\System`.
3. Apply the changes from [Server configuration](#server-configuration) to
   `Content\System\Swat4DedicatedServer.ini`.
4. Do **not** create a `LagCompensation.ini` and do **not** add anything to
   `ServerPackages`.

To uninstall, restore the backed up `SwatEquipment.u` and remove the
`ServerActors` line.

### Check that it is running

The server log (`Swat4DedicatedServer.log`) should contain, on every map load:

```
Log: Spawning: LagCompensation.LagCompensationManager
```

The mod's own messages (`LagCompensation: enabled=True ...` and the
`bLogShots` output) are script logs, which SWAT 4 hides by default. To see them,
comment out this line in `[Core.System]` of the server ini:

```ini
;Suppress=ScriptLog
```

## Server configuration

In `Swat4DedicatedServer.ini` (or `Swat4.ini` for a non-dedicated server):

1. Under `[Engine.GameEngine]`, next to the other `ServerActors` lines:

   ```ini
   ServerActors=LagCompensation.LagCompensationManager
   ```

2. Add this section at the end of the file:

   ```ini
   [LagCompensation.LagCompensationManager]
   bEnabled=True
   MaxRewindTime=0.5
   PingScale=1.0
   ExtraRewindTime=0.0
   bAddServerFrameTime=True
   bUseServerMeasuredPing=True
   SampleInterval=0.01
   TeleportDistance=512
   bCompensateAI=True
   bLogShots=False
   ```

| Setting | Default | Description |
|---|---|---|
| `bEnabled` | `True` | Master switch. |
| `MaxRewindTime` | `0.5` | Maximum rewind in seconds. Players with a higher ping are only compensated up to this value. It also limits abuse of a faked high ping. |
| `PingScale` | `1.0` | Fraction of the round trip time that is rewound. |
| `ExtraRewindTime` | `0.0` | Extra seconds added to every rewind. |
| `bAddServerFrameTime` | `True` | Adds the average server frame time (the shot is processed one frame after it arrives). |
| `bUseServerMeasuredPing` | `True` | Uses the server's own ping measurement, falling back to the scoreboard ping. |
| `SampleInterval` | `0.01` | Seconds between position samples. History length = 64 x this value. |
| `TeleportDistance` | `512` | A position jump larger than this (Unreal units) resets a player's history (respawns). |
| `bCompensateAI` | `True` | Also compensates AI pawns (COOP suspects and civilians). |
| `bLogShots` | `False` | Logs every compensated hit to the server log, for tuning (requires `Suppress=ScriptLog` to be commented out). |

### Tuning

Enable `bLogShots` and test with a high-ping player shooting a running target.
If shots still need to be led ahead of the target, increase `ExtraRewindTime`
(for example `0.03` to `0.05`). If odd hits register behind the target, lower
`PingScale`.

### Network settings worth checking

These are stock engine settings, unrelated to the mod, but SWAT 4's 2005 defaults
can make movement feel laggy even at low ping:

- Server, `[IpDrv.TcpNetDriver]`: set `MaxInternetClientRate=32000`. Without it,
  players connecting by IP can be capped at about 7,000 bytes/s.
- Client, `Swat4.ini`: `[Engine.Player] ConfiguredInternetSpeed=32000` and
  `[Engine.LevelInfo] bCapFramerate=True`.

## Building from source

The SWAT 4 script compiler (UCC) builds incrementally and needs the source code
of **every** package listed in `EditPackages`. You need the official SWAT 4 SDK
and your own copy of the game.

1. Copy the SDK's `Source\Unreal` and `Source\Game` folders into
   `LagCompensation\Source\` (do not overwrite the mod's files; see
   [Repository layout](#repository-layout)).
2. Create `LagCompensation\SystemConform\` and copy the retail `.u` files from
   `Content\System` into it (at least `SwatEquipment.u`). UCC conforms rebuilt
   packages against these files, which is what keeps the retail GUID.
3. Copy all `*.ini`, `*.int` and `shaders.spk` from `Content\System` into
   `LagCompensation\System\`, then set:
   - `Startup.ini`:
     `FilePath=..\System;..\Content\Scenarios;..\Content\Maps;..\..\Content\System;..\..\Content\Scenarios;..\..\Content\Maps;..\..\Content\Test\Maps`
   - `StartupUCC.ini` (**must be a single line**):
     `FilePath=..\Source\Game\System;..\Source\Unreal\System;..\Content;..\..\Content;..\..\Content\System;..\..\Content\Classes`
   - `Default.ini` and `UCC.ini`: add `EditPackages=LagCompensation` at the end
     of the `EditPackages` list.
4. Run `CompileLagCompensation.bat`. Expected output:

   ```
   Conforming: SwatEquipment            (only when SwatEquipment changed)
   Success - 0 error(s), 0 warning(s)
   ```

   The warning `Failed to load '..\SystemConform\LagCompensation.u'` is normal
   (the package is new, there is no original to conform to).

**Never** delete or replace the files in `SystemConform` after a release: without
them a rebuilt `SwatEquipment.u` gets a new GUID and unmodified clients can no
longer join.

## Repository layout

```
LagCompensation/
  README.md
  CompileLagCompensation.bat        builds the packages
  LaunchLagCompensationServer.bat   dedicated server with the mod
  LaunchLagCompensation.bat         game with the mod (non-dedicated host)
  Source/
    Game/
      LagCompensation/Classes/
        LagCompensationManager.uc   the lag compensation (server only)
        LagCompensation.upkg        marks the package ServerSideOnly
      SwatEquipment/Classes/
        LagCompensation/LagCompensationHook.uc   new: hook interface
        Bases/ClipBasedWeapon.uc                 modified: BallisticFire hook
        Bases/RoundBasedWeapon.uc                modified: BallisticFire hook
```

Compiled packages (`LagCompensation.u`, `SwatEquipment.u`) are distributed in
the release archive, not in the repository.

## Known limitations

- Only the target's **position** is rewound, not its pose (crouch, lean) or body
  rotation.
- Taser, pepper spray, the pepperball launcher and grenades use their own logic
  and are not compensated.
- AI shooters and the host of a non-dedicated server have no latency, so they
  are not compensated (they do not need it).
- Base game only; The Stetchkov Syndicate is not supported.

## Credits and license

- Built with the official SWAT 4 SDK by Irrational Games.
- `ClipBasedWeapon.uc` and `RoundBasedWeapon.uc` are SDK files with small
  modifications; SWAT 4 and its SDK are property of their respective owners.
  This repository does not redistribute the SDK or the game's packages.
