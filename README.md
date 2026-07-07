# The Binding of Isaac — macOS launch-crash fix

**Fixes the instant crash-on-launch of *The Binding of Isaac: Rebirth / Afterbirth / Afterbirth+* on modern macOS (Sequoia / macOS 15) on Apple Silicon under Rosetta 2.**

If the game dies immediately when you press **Play** — no window, straight back to the Steam library, or a segfault crash report — this fixes it. No game files are modified, nothing is cracked, and the fix is a small open-source shim you build yourself.

<p align="center">
  <img src="docs/demo.gif" alt="The Binding of Isaac launching and running on macOS 15 after applying the fix" width="560">
</p>

---

## Is this you?

- macOS 15 (Sequoia), and probably late 14 (Sonoma), on an Apple Silicon Mac (M1/M2/M3/M4).
- The game launches through Rosetta 2 (it's an x86-64 build).
- Pressing **Play** does nothing, or the game crashes instantly.
- The crash report (in **Console → Crash Reports**, or `~/Library/Logs/DiagnosticReports/`) shows a segfault (`EXC_BAD_ACCESS` / `SIGSEGV`) at an address like **`0x00007fff5fc01008`**, often with `steamloader.dylib` in the backtrace.

If that matches, read on.

---

## Requirements & compatibility

**The installer checks for these and offers to install anything missing — you don't have to do it yourself.** Listed here for transparency:

- **Apple Command Line Tools** — provides `clang` to compile the shim (~1 second). The installer runs `xcode-select --install` for you if needed.
- **Rosetta 2** (Apple Silicon only) — the game is an x86-64 app, so it runs through Rosetta. The installer offers to install it if it's missing.
- **Steam**, with the game installed, in the default location (`~/Library/Application Support/Steam`).

No other libraries, frameworks, or runtime dependencies — the shim uses only what macOS already ships (`libSystem`: `dlfcn`, `signal`, `ucontext`).

**Confirmed working on:**

| Component | Tested configuration |
|---|---|
| macOS | 15.7.3 Sequoia (build 24G419) |
| Mac | MacBook Pro, Apple M2 Max, 32 GB |
| Architecture | Apple Silicon (arm64) via Rosetta 2 |
| Toolchain | Apple clang 17.0.0 (Command Line Tools) |
| Game | Afterbirth+ v1.06.T1 (Steam appid 250900) |

**Expected to also work on** (same root cause and a version-agnostic fix — reports welcome):

- Other **Apple Silicon** Macs (M1/M2/M3/M4) on macOS 13 Ventura, 14 Sonoma, and 15 Sequoia.
- **Intel** Macs on recent macOS, where the game runs x86-64 natively (no Rosetta). The shim is built for x86-64 either way, so it should apply; this hasn't been tested yet.
- The base **Rebirth** and **Afterbirth** editions, not just Afterbirth+ — they share the same Steam DRM loader.

The fix itself doesn't depend on any specific macOS version: it uses stable POSIX signal handling and matches the legacy dyld shared-cache address range, which has been constant for many macOS releases.

---

## Install (the easy way)

You don't need to know anything about coding. The installer detects your Mac, installs anything it needs, and sets up Steam for you automatically — no paths to type, no Steam settings to edit.

1. At the top of this page, click the green **`< > Code`** button → **Download ZIP**.
2. Open your **Downloads** folder and double-click the ZIP to unzip it. You'll get a folder named `isaac-afterbirth-macos-fix-main`.
3. Open that folder and **double-click `install.command`**.
   - **macOS will probably show "Apple could not verify… is free of malware." That's expected — it shows this for _every_ app and script that isn't from the App Store, no matter what it is.** To run it: **right-click** `install.command` → **Open** → **Open**. (Still blocked? Go to  → **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.) You can read the whole script first if you like — it's plain text.
   - Rather not deal with that dialog at all? Use the one-line install just below — it skips the warning entirely.
4. A Terminal window opens and walks you through it in plain language. If it needs Apple's developer tools or Rosetta, it'll offer to install them. When it asks to close and reopen Steam to save the setting, say **yes**.
5. When it says **"All done 🎉"**, open Steam and press **Play**.

That's it. To undo everything later, double-click **`uninstall.command`** the same way.

<details>
<summary>Prefer the terminal? One-line install</summary>

```sh
curl -fsSL https://raw.githubusercontent.com/YorkWestenhaver/isaac-afterbirth-macos-fix/main/install.command | bash
```

Or clone and run it: `git clone …` then `./install.command`. It's the same script either way — it checks dependencies, builds the shim, and sets your Steam Launch Options automatically.
</details>

<details>
<summary>Setting the Launch Options by hand (if the automatic step didn't run)</summary>

The installer normally does this for you. If it couldn't (e.g. Steam wouldn't close), set it yourself:

1. In Steam, right-click **The Binding of Isaac: Rebirth** → **Properties**
2. **General** tab → **Launch Options**
3. Paste this line, replacing `YOU` with your macOS username:

   ```
   "/Users/YOU/Library/Application Support/IsaacDyldShim/isaac_launch_wrapper.sh" %command%
   ```

   (Steam's Launch Options on macOS don't understand `~`, so it has to be the full path.)
4. Close Properties and press **Play**.
</details>

---

## What's actually wrong (the root cause)

The game is wrapped in Steam's DRM. At launch, Valve's **`steamloader.dylib`** runs a routine (`CGlobalInitter::CrackMainImage`) that decrypts the real game code in memory and jumps into it. So far so good — that part still works.

The decrypted code then calls one of steamloader's own **ancient dyld-compatibility stubs** (`_dyld_func_lookup` / `_dyld_lookup_and_bind`) to look up a dyld-internal function by name — the way Mac software did it back around 2006.

That stub is a classic *lazily-bound* stub: it jumps through a pointer slot that's supposed to be filled in at load time. On modern macOS, **that slot is never filled in.** It still holds the original build-time placeholder, which points at the **old, fixed, pre-ASLR** address where the dyld shared cache used to live (`~0x7fff5fc00000`). Today that address space is randomized and **nothing is mapped there**, so the call jumps into unmapped memory and the process instantly segfaults at `0x7fff5fc01008`.

**This is a bug in Valve's very old, unmaintained DRM loader — not in the game, and not in your Mac.** It's why no amount of verifying game files, reinstalling, or tweaking launch flags helps.

### How the fix works

`isaac_dyld_shim.dylib` is loaded into the game at startup (before steamloader). It installs a `SIGSEGV`/`SIGBUS` handler. When the crash happens, the handler recognizes the fault by its telltale legacy address, figures out which symbol the old stub was trying to resolve (from the CPU registers, using the original `_dyld_func_lookup(name, &out)` calling convention), resolves it properly with `dlsym`, writes the answer back, and **resumes execution as if the call had succeeded.** The game continues into normal startup and runs.

Any *other* crash is passed straight through to the normal handler, so real bugs are never hidden.

There's a second, macOS-specific wrinkle the wrapper script handles: `/bin/bash` is a SIP-protected system binary, so macOS **strips `DYLD_*` environment variables** when it runs a shell script. That would accidentally drop Steam's *own* injection of `steamloader.dylib`. The wrapper re-injects both steamloader and the shim, then hands off to the game. (Details in the comments of [`src/isaac_launch_wrapper.sh`](src/isaac_launch_wrapper.sh).)

---

## What it does to your Mac

Nothing invasive — here's the whole footprint:

- **It doesn't modify the game.** No game files are changed; the fix only *references* files already on your machine.
- **It all lives in one folder** (`~/Library/Application Support/IsaacDyldShim/`), plus one line added to the game's Steam Launch Options (backed up first).
- **It's fully reversible.** Double-click `uninstall.command` to remove the folder and clear the Launch Options, restoring the default behavior.
- **It's open source and you build it yourself**, so you can read exactly what it does before running it.

---

## Verifying it worked

After pressing Play you should reach the intro cutscene and the main menu. To confirm the fix is doing its job, enable debug logging: open `~/Library/Application Support/IsaacDyldShim/isaac_launch_wrapper.sh`, set `ISAAC_SHIM_DEBUG=1` near the top, relaunch, then look at `~/Library/Application Support/IsaacDyldShim/game_output.log`. You should see:

```
[isaac-shim] installed, watching for legacy dyld address faults
[isaac-shim] caught stale legacy-dyld code fetch at 0x7fff5fc01008 -- emulating _dyld_func_lookup
[isaac-shim] lookup "__dyld_lookup_and_bind" -> 0x...
[isaac-shim] resuming at return address 0x... (result=found)
```

That's the crash being caught and repaired in real time.

---

## Troubleshooting

- **"Apple could not verify 'install.command' is free of malware"** (or "unidentified developer") — this is normal for any tool that isn't from the App Store; it's not specific to this fix. **Right-click** the file → **Open** → **Open**. If there's no Open button, go to  → **System Settings → Privacy & Security**, scroll down to the message about `install.command`, and click **Open Anyway**. (Or skip it entirely with the one-line terminal install, which macOS doesn't gate.)
- **"clang: command not found"** — install Apple's Command Line Tools: `xcode-select --install`, then run the installer again.
- **Game still closes instantly with no crash report** — this usually means `steamloader.dylib` wasn't found. Check that Steam is in the default location (`~/Library/Application Support/Steam`). If it's elsewhere, edit the `STEAMLOADER` path near the top of `isaac_launch_wrapper.sh`.
- **"Failed to spawn process / OS Error 260" in Steam's logs** — your Launch Options are wrong. They must be the wrapper path in quotes followed by `%command%`. Do **not** use the Linux `DYLD_INSERT_LIBRARIES=... %command%` form; it doesn't work on macOS.
- **A Steam update replaced `steamloader.dylib`** — no action needed; the wrapper points at it by path, so it keeps working. (If Valve ever *fixes* the underlying bug, the shim simply never fires — it becomes a harmless no-op.)
- **Steam "Verify integrity of game files"** — safe; the fix doesn't touch game files, so verification won't disturb it.

---

## Uninstall

Double-click **`uninstall.command`** (right-click → Open the first time, same as install). It clears the game's Steam Launch Options and deletes the fix folder — nothing else is touched.

---

## Might this help other games?

Possibly. Any old Steam-DRM-wrapped **Mac** game that crashes on launch at an address around `0x7fff5fc0xxxx` is likely hitting the *same* stale-legacy-dyld-stub bug in `steamloader.dylib`. The shim isn't Isaac-specific — only the wrapper's game path and the Launch Options are. If you try it on another title and it works, please open an issue so others can find it.

---

## Credits & license

Diagnosed by reverse-engineering `steamloader.dylib`'s DRM decryption path and live-debugging the crash with `lldb`. Released under the [MIT License](LICENSE). Not affiliated with or endorsed by Valve or Nicalis.
