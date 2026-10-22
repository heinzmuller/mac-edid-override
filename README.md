# mac-edid-override — safety hardening

A fork of [kdotc2/mac-edid-override](https://github.com/kdotc2/mac-edid-override) for applying a custom runtime EDID to **one identified external monitor** on Apple Silicon.

This uses private macOS APIs. It is not an Apple-supported mechanism and can stop working after macOS updates. It changes what macOS sees, not the monitor's firmware. Keep the built-in display or another unaffected display available while testing.

## What changed

- Matches manufacturer, product, numeric serial and serial descriptor from your profile. Refuses missing serials and ambiguous matches; never falls back to the first external display.
- Validates EDID header, length, declared block count, block checksums and DisplayID section checksums before calling display APIs.
- Checks availability of private functions and verifies readback. A readback failure triggers a factory reset attempt and returns failure.
- Installation only stages files. A **separate interactive test** must be confirmed before enabling startup.
- An independent watchdog restores the target's factory EDID on timeout or parent exit. It must signal readiness before the test applies anything.
- Approval is tied to the exact profile bytes; modified profiles need another test.
- No automatic daemon restart loop. A real apply/readback failure stops background attempts and revokes approval.
- Uses argument-based `launchctl` calls, releases display services, coalesces change notifications and checks periodically every 30 seconds.
- Diagnostic program uses public CoreGraphics APIs instead of private binary layouts.

## Requirements

- Apple Silicon Mac, macOS 15 or later, Xcode Command Line Tools.
- Direct USB-C/Thunderbolt/DisplayPort connection exposing a readable `DCPAVServiceProxy`.
- A valid EDID **exported from your own monitor**, with your monitor's serial identity and suitable timings. A generic profile or another monitor's EDID will not target your display correctly.

The upstream author's tested configuration was an M1 Max with a Dell U4025QW. The hardening in this fork has build and offline test coverage; live apply, rollback, reconnect and sleep/wake testing is still required. Valid checksums do not establish that a timing is suitable for your hardware.

Do not run alongside another EDID override tool. The rollback restores factory EDID, not another application's previous custom override. It does not restore colour profiles or arbitrary macOS preferences.

## Stage, test, then enable

Run as your normal user, **without sudo**:

```sh
./install.sh /absolute/path/to/your-monitor-edid.bin
```

No default monitor profile is selected. Installation validates the file and stages binaries under `~/.config/edid-override`; it does not apply an override or create a startup service.

Test in an interactive terminal with your target monitor connected:

```sh
~/.config/edid-override/edid_override --test ~/.config/edid-override/edid.bin
```

Select the desired refresh rate in System Settings. Type `KEEP` and Enter within 35 seconds **only if the picture is stable**. Otherwise the independent watchdog attempts a factory reset, at its 45-second deadline. Closing the terminal or the test process also triggers rollback while the watchdog remains running. A system/process kill affecting the watchdog itself cannot be recovered by that watchdog; reconnect the monitor or restart instead.

A successful test saves approval, but still does not enable startup. To opt in:

```sh
~/.config/edid-override/edid_override --enable
```

This creates a user LaunchAgent for login and background reconnect/wake handling. No administrator permission is required. Your profile remains local.

## Diagnostics and recovery

```sh
~/.config/edid-override/edid_check
~/.config/edid-override/edid_override --status
~/.config/edid-override/edid_override --reset
```

Reset stops the startup service, revokes approval and clears the runtime override only on the matching monitor. If the target is disconnected, unreadable or ambiguous, reset refuses to touch another display. Reconnect or restart to clear any outstanding runtime override. The saved LaunchAgent is not loaded again until `--enable` is used (after another test).

Uninstall with:

```sh
./uninstall.sh
```

The uninstaller stops the service even if the binary/profile is damaged, attempts a target-specific reset, then removes the staged files and LaunchAgent. Keep your original EDID and any recovery files separately. If reset cannot be verified, it tells you to reconnect or restart.

## Offline checks

```sh
./tests.sh
```

This builds both programs with warnings treated as errors, runs validation/identity/watchdog-decision self-tests, rejects malformed fixtures, and validates generated dummy profiles. It does not install anything, call a display-changing API or register a service.

No real monitor EDIDs are bundled. Tests generate synthetic profiles with dummy identities in a temporary directory and remove them afterward. Supply your own monitor’s profile locally; test fixtures are not display configurations.

## License

MIT; upstream attribution retained in LICENSE.
