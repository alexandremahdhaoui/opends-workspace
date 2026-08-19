# CLAUDE.md — opends workspace

A Rust rewrite of DS4Windows. Read a DualSense or a DualShock 4 on Windows. Map
it. Present it to games as an Xbox pad.

Read `~/.claude/CLAUDE.md` first. Those rules apply here.

## The CLAUDE.md files are the source of truth

This one and the one in each repo. Nothing else is authority. `FOLLOWUP.md`
holds state and never lessons. A lesson belongs here.

Behaviour is checked against the reference checkouts under `reference/`.

## Hard rules for this workspace

**Windows 11 and x64.** Windows 10 is best effort and nothing bends for it. No
x86 and no ARM64. This deletes the Windows 10 INF branch, the Windows 10 VHF
report length bug workaround, and two thirds of the build matrix.

**We ship zero kernel code.** The driver is UMDF and runs in user mode. The only
kernel pieces in the path are Microsoft's own `vhf.sys` and `xinputhid.sys` and
both are already installed on every Windows 11 machine.

**No socket. Not one.** The tool needs no internet. There is no `http_adapter`
and no allowlist because there is nothing to allow. The `netcheck` stage fails
the build if a socket API appears anywhere in the tree.

**No third party code is installed or executed. Ever.** `reference/` is read
only and gitignored. Nothing there is built and nothing there is run. It holds
committed exes and msis and dlls and none of them may execute.

**We write our own driver or we need none.** No ViGEmBus. No VIIPER. No usbip.
No HidHide. No FakerInput. One driver we own replaces all five.

**No auto updater.** The reference downloads an exe and runs it. That is the one
real risk in it. See `docs/security-audit.md`.

**No image and no archive is ever opened.** Source code only.

## The repos

| Repo | Owns | Builds on Linux |
|---|---|---|
| `opends-workspace` | The workspace root files | Yes |
| `opends-spec` | Every config key and the driver protocol | Yes |
| `opends-core` | The domain. No I/O. | Yes |
| `opends-app` | Adapters, drivers, binaries | Yes, and cross compiles |
| `opends-uhid` | The UMDF VHF driver | **No** |

`opends-uhid` is **not** a `members` entry in the root `Cargo.toml`. Adding it
makes `cargo build` at the workspace root fail on Linux for everyone.

`golden-configgen` from the playground workspace is reused unchanged.

## The virtual pad is a hardware ID trick, not USB emulation

This is the load bearing fact of the project.

**XInput does not enumerate HID devices.** The XUSB driver exposes an XInput
interface and also exports a HID interface for DirectInput. The arrow points
that way. So a plain virtual HID gamepad is invisible to an XInput game.

The way round it is a hardware ID. `C:\Windows\INF\xinputhid.inf` holds this.

```
%GIP_Hid.DeviceDesc%=GIP_Hid, HID\VID_045E&PID_02FF&IG_00
[GIP_Hid]
CopyFiles=XInput_Hid.CopyFiles    ; xinputhid.sys
```

Any HID device whose hardware IDs include that string gets `xinputhid.sys`
loaded on top, and that driver is what hands it to XInput. The `IG_` token is
Microsoft's marker for an XInput capable device. Seven more Xbox product IDs are
listed beside it.

`xinputhid.inf` is the only inbox INF matching an `IG_` ID. **Read it before
believing anything else about XInput.**

## VHF supports user mode

`VhfUm.lib` and the in-box `VhfUm.dll`. The Microsoft conceptual page saying
kernel mode only is stale. The `vhf.h` DDI page is right and says both.

So the driver is UMDF. No kernel code. A bug is a crash in `WudfHost.exe` and
not a bluescreen.

The runtime is already on the machine. `vhfum.dll`, `vhf.sys`, `hidvhf.inf`,
`WUDFx02000.dll`, `WudfHost.exe`. Nothing to ship.

## Signing is free. Self signing works. Proven.

Installed on this machine 2026-08-18 with Secure Boot on and test signing off.
`pnputil` lists it as `oem68.inf` with `Signer Name: opends` and the device
reports `Status OK`.

**No EV certificate. No OV certificate. No Partner Center. No attestation.**

The recipe, all done by `opends-setup.exe`.

1. `New-SelfSignedCertificate -Type CodeSigningCert`
2. `makecat` over a `.cdf` listing the dll and the inf
3. `signtool sign` the catalog
4. Add the certificate to **both** `LocalMachine\Root` and
   `LocalMachine\TrustedPublisher`. `Root` makes the chain validate.
   `TrustedPublisher` suppresses the prompt.
5. `SetupDiCreateDeviceInfoW` then `DiInstallDriverW`

WinUHid needed a purchased Sectigo certificate only because it never adds its own
to `Root`. That was a distribution choice and not a requirement.

`inf2cat` was never needed. It ships with the WDK installer we do not have.
`makecat` comes with the SDK and does the same job from a `.cdf`.

**This is the opposite of the exe.** Smart App Control refuses self signed
binaries and wants a Microsoft Root Program chain. Driver packages accept a
certificate we put in the trust store ourselves.

## The binary protocol is declared once, in Rust

`opends-spec/src/protocol.rs` owns the IOCTL codes and the `#[repr(C, packed)]`
structs. `opends-protogen` emits `opends-uhid/src/zz_generated_protocol.h` from
it. **Never edit that header.** The `protocol-match` stage regenerates it and
fails on any diff.

The generated header carries `C_ASSERT` on every struct size, computed from
Rust's `size_of`. So the C compiler proves the two sides agree on layout rather
than us hoping they do.

**cbindgen was tried and rejected.** It silently drops `#[repr(C, packed)]`
structs with no warning at all, and it cannot evaluate a `const fn`, so it
emitted none of the IOCTL codes. A generator that quietly omits the only thing
you care about is worse than no generator. `opends-protogen` is 100 lines and
under our control.

The IOCTL values are written as literals so they are trivially emittable, and a
test asserts every one equals what the `ctl_code` formula produces. The formula
stays the authority and the literal stays the artifact.

## Bump DriverVer every build or your fix never ships

`DriverVer` was hardcoded to `08/18/2026,1.0.0.0`. Three installs in a row
deployed three different DLLs and Windows kept the first one, because a package
with the same version and rank is not an upgrade. Every fix looked like it had
been installed and none had.

`hack/build.sh` now stamps `DriverVer` from the current date and time, so it
always increases. Never hardcode it again.

**How to tell it happened.** `pnputil /enum-drivers` shows the same
`Driver Version` after an install that was supposed to change the driver.

## The driver is not a port of WinUHid

It is a smaller reimplementation, 369 lines against their 1478, written after
reading their design. Do not assume behaviour carries over.

Not taken from them, and each may matter: the per file object device model, the
manual dispatch queue that pends `IOCTL_GET_NEXT_EVENT` until an event exists,
the report descriptor parser that computes report sizes, and their async
operation completion tracking.

Taken from them: `WdfFdoInitSetFilter`, the VHF config shape, the symbolic link,
the gamepad only idea, and the IOCTL layout.

## The driver is an upper filter on VHF, not a function driver

`WdfFdoInitSetFilter(DeviceInit)` before `WdfDeviceCreate`. Miss it and nothing
works, in a way that looks fine.

The INF installs `vhfservice` as the function driver through
`Needs = vhfservice.NT`. Our UMDF driver sits **above** it. Without the filter
call our driver tries to own the FDO too, collides with VHF, and never publishes
its symbolic link.

The symptom is brutal because it lies. Device Manager reports `Status OK` and
`CM_PROB_NONE`, `pnputil` lists the package with the right signer, and
`CreateFileW(\\.\OpenDsUHid)` returns **error 2, the device does not exist**.

**A device reporting `Status OK` is not a device that works. Only opening it
proves anything.** That is what `--vpad-check` is for.

The queue also needs `PowerManaged = WdfFalse`, as a filter's queue should.

## The driver refuses to make anything but a gamepad

WinUHid's device object is admin only, and its INF explains that an emulated HID
device could otherwise bypass UIPI. That is correct for WinUHid because it is
truly generic. It parses the descriptor only for report sizes and never looks at
usage pages, so it will happily create a virtual **keyboard**. A low privilege
process could then inject keystrokes that arrive as trusted HID input.

Ours checks the descriptor and refuses anything that is not Usage Page `0x01`
Generic Desktop, Usage `0x05` Gamepad.

That one check buys back the ACL. Interactive users can create a pad and the exe
never needs elevation after install. Installing the driver still needs admin
once and always will.

It costs nothing we wanted. The driver stays written once and never changes when
a pad is added, because gamepad only is a fixed rule and not a device list.

**A virtual gamepad cannot type. That is the whole argument.** It can drive
gamepad navigation in shell and UWP surfaces, which is a real but much smaller
surface than a keyboard. UAC is on the secure desktop and takes no injected
input.

## The lightbar output report never actually fired

`run()` called `controller.send_output_to_all(&wanted)` once, right after
attaching sessions and before the poll loop ever ran. `send_output` requires
a known transport, and transport is only set inside a session's first
successful decode. So that call always ran against sessions with
`transport() == None` and silently no-op'd every single time. "lightbar set"
never printed under normal play, only when a game later sent rumble through
the virtual pad, which triggers the same call from inside the loop.

Bluetooth DualSense/DualShock4 pads are known to start in a compact report
mode with no touchpad or gyro telemetry, and only switch to the full report
once the host sends an output report. If that theory holds, this bug is also
why gyro and touchpad position were never visible over Bluetooth: nothing
ever sent the pad the output report that would unlock them.

Fixed by moving the send inside the loop, gated on a `lightbar_confirmed`
flag so it only prints once. It now retries every iteration until transport
is known, which takes one extra 4ms tick, not a redesign.

**A one-shot startup call that depends on state the loop hasn't produced yet
is a bug waiting to be silent.** `send_output_to_all` has always correctly
required a known transport; the mistake was calling it once, too early,
instead of retrying until the precondition holds.

## `--watch-pad` was button-only by design, and stick decode had never actually been watched

Moving a real stick left or right printed nothing. Not a bug in decode.
`Update::changed()` only ever checked `pressed != 0 || released != 0` —
pure stick movement was invisible on purpose, because an earlier session
found continuous Bluetooth sensor jitter flooding the terminal and the fix
at the time was to gate output on button transitions only. That fix also
hid the one thing we most needed to see while validating the real-hardware
path: whether stick decode reacts to a real push at all.

Every printed line in the session that first surfaced this only existed
because of an unrelated button event, so nothing in that log actually
proved or disproved stick decode. Coincidence, not evidence.

Fixed with a threshold, not a raw delta. `Session` now tracks a `reported`
baseline separate from the immediately-previous sample, and a stick counts
as moved only when it drifts more than `STICK_CHANGE_THRESHOLD` (0.15, about
15% of full throw) from wherever it was last reported. Comparing against the
literal previous sample would have reopened the jitter flood, since adjacent
Bluetooth samples differ by a point or two even at rest. Comparing against
the last reported position is a level-crossing detector, the same shape as
button edge-detection, and both concerns are satisfied by the one field:
sensor noise at rest stays under threshold forever, a real push crosses it
once.

## Reinstalling over an existing device reconfigures it in place, and that can fail

After a full session of repeated install/test cycles, the driver stacked up
thirteen registered package versions (`oem68` through `oem80`) on the same
`Root\OpenDsUHid` device node, because our own install code checked
`device_exists()` and, when true, skipped `create_device` entirely and asked
`DiInstallDriverW` to reconfigure the existing device in place instead.

That reconfigure failed for real: `setupapi.dev.log` showed
`Configuring device failed : 0x0000000D`, a fallback to standard device
install, and that failing too inside `WUDFCoinstaller.dll` with
`Error 87: The parameter is incorrect`. Our own app surfaced this correctly
as `installing the driver package. Windows said 0x80070057` — once
`setup_log_adapter` existed to make it visible at all.

Fixed by never reconfiguring in place. `recreate_device` now removes the
existing device first, then always calls `create_device` fresh, matching
what a person doing "uninstall then reinstall" by hand would do. Verified for
real: the exact same rebuild-and-reinstall cycle that reliably failed before
this fix completed cleanly afterward, confirmed by `setupapi.dev.log`
recording `Configuring device completed` and `Exit status: SUCCESS`.

**A live client holding the device open while reinstalling is a plausible
compounding cause, not just a theory.** If `OpenDS.exe --watch-pad` is still
running when the driver gets reinstalled underneath it, the device can't be
cleanly torn down and recreated. `hack/auto-verify.sh` now checks for and
stops any running `OpenDS`/`OpenDS-Setup` process before it starts, since
that risk costs nothing to remove even without full certainty it was the
original cause.

## An output write that was never actually confirmed to finish

Two fixes in a row changed nothing observable, and that itself was the signal
worth reading. Both fixes were real and both are still correct, but neither
could have mattered, because `hid_adapter::write_report` never told us
whether a write had actually happened.

The handle is opened with `FILE_FLAG_OVERLAPPED`, so every `WriteFile` is
asynchronous by contract. `write_report` created a throwaway
`OVERLAPPED::default()` on the stack with no event handle, called `WriteFile`,
and treated `ERROR_IO_PENDING` — the normal, expected result for an overlapped
write that has not finished yet — as success. Nothing ever called
`GetOverlappedResult` to find out what actually happened. The stack-local
`OVERLAPPED` went out of scope on return while the OS could still have been
using it. `read_latest` right next to it does this correctly: a persistent
`Box<OVERLAPPED>` with a real event, tracked across calls, checked with
`GetOverlappedResult` before the buffer is trusted. `write_report` never
followed the pattern sitting right beside it.

The result: every output write silently claimed to succeed regardless of
whether the pad received anything. `session.send_output` returned `true`,
`"lightbar set"` should have printed — and even that never happened, which
was the tell that something upstream of the CRC/report-shape fix was
swallowing the real failure.

Fixed with its own persistent `write_overlapped: Box<OVERLAPPED>` and event,
mirroring the read path, and an explicit blocking `GetOverlappedResult` call
so `write_report` cannot return `Ok` until Windows confirms the byte count.
`HidError::Write` now carries the actual Windows error code instead of just a
length, and a new `HidError::ShortWrite` covers a completed write that wrote
fewer bytes than asked. `Session` remembers the last output error so
`run()` can print the real reason once instead of nothing at all.

**Silence after two plausible fixes is not proof the theory was wrong. It is
often proof the failure is one layer further down than either fix reached.**
The CRC and report-shape fix was still necessary and still correct by the
reference. It just could never have shown up, because the layer underneath it
was reporting success unconditionally.

## A Bluetooth pad in Basic mode still needs the Bluetooth output shape

Touchpad clicks worked over Bluetooth. Finger position and gyro never did,
even after the dead lightbar call was fixed to actually fire. The pad stayed
in `BluetoothBasic` forever.

`output::build`'s only branch on transport was `BluetoothFull => bt shape,
_ => usb shape`, so `BluetoothBasic` fell into the USB branch: report ID
`0x02`, no CRC. Checked both `DualSenseDevice.cs` and `DS4Device.cs` in the
reference. Every output-shape decision there branches on
`conType == ConnectionType.BT`, a single flag for the physical link, never on
which input report the pad happens to be sending. Output over Bluetooth is
always the BT shape, `0x31` with a CRC for DualSense, regardless of whether
input is currently Basic or Full.

So every output write we sent to a Basic-mode pad carried the wrong report ID
and no checksum. The pad had every reason to ignore it, including the one
output report that plausibly unlocks Full input mode in the first place.

Fixed. `Transport::needs_crc()` is now `!matches!(self, Self::Usb)`, and both
`build_dualsense`/`build_dualshock4` branch on `Usb` explicitly and treat
`BluetoothBasic` and `BluetoothFull` identically. A pre-existing test had
encoded the old, wrong assumption and correctly failed the moment this
changed; fixed the test to match the verified reference behavior, not the
other way around.

**A `_` catch-all in a match on transport is a place bugs hide.** It reads as
"handles the rest," but "the rest" quietly became "everything that isn't the
one case I actually tested."

## Touch and gyro were decoded but never printed

`render_update` formatted buttons, triggers, and sticks. `PadState.touch` and
`PadState.motion` were decoded correctly into every `PadState` and never once
reached the CLI. Asked directly whether touchpad motion and gyro were
visible, and the honest answer was they could not have been, independent of
whatever the lightbar/BT-mode bug turns out to explain.

Fixed. The line now always carries `touch1=`, `touch2=`, `gyro=`, `accel=`.
Widened the same threshold-crossing pattern used for sticks to cover finger
position too, so a touchpad drag gets its own printed line the same way a
hard stick push does, and a finger lifting off counts as a change even though
its last position does not move.

## Analog fields need their own print rate, separate from button edges

Asked directly to debounce touch and gyro printing so it would not drown out
button and stick lines once those fields start actually changing. Reasonable
ahead of the fact: the threshold-crossing gate on sticks and touch already
limits how often they trigger a line, but a slow continuous drag can still
cross that threshold several times a second.

Added `AnalogThrottle` in `cli_driver.rs`, not in `pad_controller.rs`. This is
a presentation cadence, not a correctness signal, so it stays out of `Update`
and out of core. A button press or release is never throttled, only a line
that exists purely because a stick or the touchpad moved. The interval is a
constructor parameter rather than a hardcoded `Instant::now()` call baked
into the throttle, so a test can use a 5ms interval and a real 15ms sleep
instead of waiting on the real one-second default.

## A HID report descriptor's declared bit length is not optional

`opends-core::controller::vpad::REPORT_LEN` was 16. Summing every `0x81`
Input field the Xbox One descriptor declares, in order, including the
padding fields and the trailing Battery Strength byte, comes to 136 bits,
which is 17 bytes. The descriptor was copied byte-for-byte correct from
`WinUHidXOne.cpp`. The packed report was one byte short of what it declared.

The symptom was not a length error anywhere. `--vpad-check` reported `virtual
pad created` and `XInput sees 1 controller(s)` — enumeration worked, because
that only depends on the hardware ID and the descriptor parsing cleanly. Every
field then read back as zero, because the HID stack expects an input report
exactly as long as the descriptor's own Input field total, and a
short-by-one-byte report is not the same report.

**Never trust a report length constant. Derive it from the descriptor and
compare.** A test now sums every field width the descriptor declares,
including padding, and asserts it against `REPORT_LEN` — so a future change
to the descriptor that is not matched by a change to `pack()` fails a test
instead of failing silently as an all-zero pad.

## Keep pad definitions out of the driver

WinUHid's driver knows nothing about gamepads. That is why it never needs
resigning when a pad is added.

Ours goes further. The report descriptors and the report packing live in
`opends-core`, which is pure, so they are unit tested on Linux with no driver
installed and no pad plugged in.

## What the customer gets, and what the driver adds

| | Exe alone | Exe plus driver |
|---|---|---|
| Pad to keyboard and mouse | Yes | Yes |
| Lightbar and rumble and adaptive triggers | Yes | Yes |
| Hide the pad from other apps | Yes | Yes |
| **Analog sticks and triggers in a game** | **No** | **Yes** |
| **An XInput only game sees the pad** | **No** | **Yes** |

**The driver is about analog, not just enumeration.** A keystroke is on or off.
A stick mapped to two keys steers hard left or straight and nothing between.

**Game Pass titles never read raw HID.** A DualSense does nothing in Forza
Horizon 6. Tested 2026-08-17. That is why the driver is the finish line.

## The reference

| Repo | Use |
|---|---|
| `hbashton_DS4Windows` | Port from this. 281 files. 160438 lines. The only fork still moving. |
| `ds4windowsapp_DS4Windows` | Cross checks only. Stale. |
| `jays2kings_ds4windows` | History only. Dead since 2021. |
| `cgutman_WinUHid` | The driver design. MIT. Read, never built, never run. |
| `Paliverse_DualSenseX` | **Nothing. It ships no source.** |

**DualSenseX has no code.** Its one `.cs` file is the README pasted inside an
empty class. It does not compile. Adaptive triggers come from DS4Windows
`TriggerEffects.cs` instead.

The port is GPL-3.0 because DS4Windows is. That is not a choice we get to make.

## Build and test

```sh
forge build
forge test-all
```

**`cargo test` is not the gate. `forge test-all` is.** Stages that never run
under cargo are exactly the ones that catch real problems.

**`unit-windows` is not optional.** Without it every `cfg(windows)` adapter is
compiled by the cross build and never run, while the Linux stage happily tests
the `cfg(not(windows))` stub beside it and reports green. That is two suites
agreeing about code neither of them executed.

## Parity against the reference is a cited test, not a live diff

Asked directly whether any gate checks our ported constants against
DS4Windows. None existed. The plan named a `parity` stage and nobody built
it.

Built the smallest honest version. A handful of tests, one per constant,
colocated with the constant they check, each named after the exact reference
file and line it cites: `sony_vendor_id_matches_ds4windows_ds4devices_cs_line_129`,
`the_bluetooth_output_seed_matches_ds4windows_dualsensedevice_cs_line_494`, and
five more covering every VID/PID and both report lengths. The test name is the
citation, since comments are banned here; a name that lies is caught the same
way a stale comment would be, by someone reading it next to the code it
claims to describe.

**This is not a live diff against upstream.** It runs no network call and
reads no file outside this repo. It is a maintained promise: if
`reference/hbashton_DS4Windows` is ever updated and a cited line changes, nothing
here notices automatically. The value is narrower and more honest than that
sounds: it stops a constant from silently drifting from what we already
verified once, and it gives a future reader an exact place to go re-check it
by hand.

**Proved each one catches drift before trusting it**, the same discipline as
`inf-check.sh` and `export-check.sh`: flipped `OUTPUT_REPORT_SEED` from
`0xA2` to `0xA3`, watched its parity test fail, put it back.

**What is not covered.** Byte offsets inside a report (sticks, triggers,
touch, gyro) are not cited against DS4Windows line numbers, because
DS4Windows's own `inputReport` indexing uses a `reportOffset` convention
that does not obviously line up with our raw-report offsets without deeper
study than this pass had time for. Citing something unverified would be
worse than citing nothing, so those offsets stay covered only by our own
decode tests and the real-report fixtures, not by a reference citation.

**Widened later: `TriggerEffect::Rigid` and `Pulse` mode bytes (`0x01`,
`0x02`) are cited against `DualSenseDevice.cs` lines 293 and 303, checked
by hand first, not assumed.** `TriggerEffect::Weapon`'s mode byte (`0x06`)
is deliberately NOT cited as DS4Windows parity, because it isn't: DS4Windows
has no `Weapon` effect at all, its closest built-ins are `SemiAutomaticGun`
(mode `0x25`), `AutomaticGun` (mode `38`), and `Machine` (mode `39`), none
of which use `0x06`. Citing a line that does not actually support the claim
would be worse than citing nothing, so `Weapon` stays uncited, covered only
by our own encode tests.

## Testing traps already paid for

**A test that touches hardware must hold with the device and without.** Assert
the relationship, never the absence. A pad reads as connected exactly when one
is plugged in. Asserting `None` passes on Linux, passes today, and fails the day
the hardware arrives.

**A capture is the test.** `--pad-walkthrough` names each button, waits for one
press and writes the raw report. That fixture replays forever. Until one lands,
the decoder has only been tested against reports we made up.

**The capture must hold the report from while the button was down.** Capturing
on release decodes to zero, and every line would be labelled with a button and
hold the bytes for nothing.

**The pad is its own oracle.** Decode a report through the report descriptor the
device publishes, using Windows' own parser, and compare it against the offset
table. That is how a hardcoded offset gets checked without trusting whoever
wrote it.

## Never overwrite a deployed exe

**Smart App Control allows per binary by hash.** It is on this machine. A build
it has allowed keeps running forever. A new build is a stranger and is usually
refused. Rust builds are not reproducible, so rebuilding the same source gives a
different hash.

**Overwrite an allowed binary and that permission is gone for good.**

`opends-app/hack/deploy.sh` writes `opends-<commit>-<md5 prefix>.exe` and never
overwrites. Old builds stay. `--list-pads` is the cheapest probe that proves
Windows let a build run.

`deploy.sh` copies and does not build. Build first or you deploy the last binary
and test nothing.

A retry only helps if the binary actually changes. Touch a source file to force
a relink, which moves the PE timestamp, which moves the hash.

There is no signing route for the exe. Self signed does not work for SAC, which
wants a certificate chaining to the Microsoft Root Program. That is the opposite
of the **driver**, where self signing works fine because we add our own
certificate to `LocalMachine\Root`.

## A Windows API result you compute and then discard is a real bug, not dead code

`driver_install_win::remove_driver` called `DiUninstallDriverW` with a
`NeedReboot` out parameter, read it into a local, and then returned `Ok(())`
without ever looking at it. The signal Windows itself was handing back, for
exactly the case where a driver package cannot fully unload because something
still has a handle on it, was computed and thrown away every time. Fixed to
return `Result<bool, InstallError>` matching `install_driver`, which already
did this correctly, and the uninstall flow now tells the user plainly when
Windows needs a restart to finish rather than silently claiming success.

**When adding an out parameter to an unsafe FFI call, grep for the guarantee
it exists to provide, and check whether it is actually being used before
moving on.** `error.code().0`-style discards are easy to miss because the
call still "succeeds."

## Smart App Control blocks fresh test binaries too

`cargo test --target x86_64-pc-windows-gnu` builds a test harness exe per target.
A binary target with no tests still gets a harness, and that harness is a brand
new unsigned exe, so SAC refuses it with `Invalid argument`.

Both `[[bin]]` entries in `opends-app` carry `test = false` for that reason. The
library holds every test and the binaries hold none.

Symptom if this regresses. `unit-windows` fails with `Invalid argument` on a
`deps/opends-*.exe` path and no test ever runs.

## `hack/auto-verify.sh` runs the whole real-hardware-adjacent loop with one human click

Repeatedly asking a person to copy-paste terminal output every few minutes is
not sustainable. `opends-app/hack/auto-verify.sh` runs the entire cycle
itself: `forge test-all` in every repo, build and sign the driver, clear both
binaries against Smart App Control, launch the installer with `--self-test`
(one UAC prompt, the one thing that must stay a human action), poll for the
exact driver version it just stamped, then run `--vpad-check` with retries
and read the result. It stops and force-closes any running `OpenDS`/
`OpenDS-Setup` process first, since reinstalling under a live client is a
real, plausible failure mode. `hack/capture-watch.sh <seconds>` is the
companion for the one thing that genuinely cannot be automated: physically
moving the pad. It records for a fixed window and reports back, so the
person's job is reduced to moving their hands, not narrating a terminal.

**`pnputil` strips leading zeros when it displays a version, the INF does
not.** `DriverVer` gets stamped as `1.0.231.0020` from `date -u +%H%M`, but
`pnputil /enum-drivers` prints `1.0.231.20`. A polling check that greps for
the literal stamped string is a permanent false negative, even though the
install genuinely succeeded, confirmed independently in
`setupapi.dev.log`. Fixed by normalizing both sides with the same integer
formatting before comparing.

**A WSL-interop-executed Windows test binary cannot reliably write a file
named like a real driver DLL, and no amount of retrying fixes it.**
`opends-uhid.dll` copies inside `unit-windows` failed with
`ERROR_ACCESS_DENIED` consistently, for up to 30 seconds of retries, in a
brand new temp directory, single-threaded, with no other explanation.
Plain `Copy-Item` for the identical file from an ordinary PowerShell prompt
succeeded immediately, proving it was not a real production risk, just this
one execution path. The fix was not a longer retry loop. It was to stop
routing that specific test through the real filesystem at all: extracted the
actual thing under test, `recreate_device`'s decision to remove-then-create
versus create-only, into its own function and tested that directly against a
mocked `DriverInstaller`, with zero disk I/O.

## WSL is a valid Smart App Control probe

`Invalid argument` from WSL and "An Application Control policy has blocked this
file" from PowerShell are the same verdict. So never hand over a build without
running it once from WSL first.

`opends-app/hack/sac-retry.sh` does the loop. It touches a source file every
attempt, because relinking is what moves the hash, and retrying identical bytes
can never change the answer.

**A probe must fail when the thing under test is absent.** The first version of
that script ran `./<name> --list-pads` and checked only for `Invalid argument`.
The name was wrong, the file did not exist, the error was a different one, and
it reported ALLOWED for a binary that was never built. It now asserts the file
exists and that the output contains real program output.

A `requireAdministrator` manifest also yields `Invalid argument` from WSL, so
the two causes look identical. Build with `OPENDS_NO_MANIFEST=1` to tell them
apart.

## The installer self elevates at runtime so it stays probeable

`requireAdministrator` in the manifest made `OpenDS-Setup.exe` impossible to
launch from WSL, so it could never be checked against Smart App Control and was
handed over blocked twice.

The manifest now says `asInvoker`. `adapter/elevation_adapter.rs` reads the
process token and, when not elevated, relaunches itself through
`ShellExecuteExW` with the `runas` verb. The customer still gets one UAC prompt
and nothing else changes for them.

`--probe` prints one line and exits before any elevation, which is what
`sac-retry.sh setup` measures.

**Clear the app before packaging the installer.** `package.sh` embeds
`OpenDS.exe`, so clearing the installer first and the app second leaves the
installer carrying a binary Smart App Control has never seen. Order is
`sac-retry.sh app` then `sac-retry.sh setup`.

**Any source edit after a clear invalidates it.** The release binary changes, so
the hash changes, so the verdict is void. Re-run both loops after the last edit.

**A clean rebuild invalidates it too, even with zero source changes.** Running
`sac-retry.sh setup` alone, some time after `sac-retry.sh app` last cleared,
re-links `OpenDS.exe` inside `package.sh`'s own build step. Rust links are not
reproducible, so that second link produces different bytes than the one
already cleared, and the installer ships an app nobody probed. Always run
`sac-retry.sh app` immediately before `sac-retry.sh setup`, back to back, with
no other cargo command between them, and verify by byte comparison afterward
rather than assuming the hashes still match.

## The installer is Rust and there is no MSI

An MSI is a relational database that `msiexec` executes. It gives Add or Remove
Programs, uninstall and upgrade handling. **It does not give the wizard.** The
Next and Finish dialogs come from UI tables that WiX ships prebuilt.

So `opends-setup.exe` is a plain Win32 wizard in Rust. It self elevates through
a `requireAdministrator` manifest embedded by `windres` from `build.rs`, shows a
progress bar, and writes the Add or Remove Programs key itself.

Nothing about the driver install needs MSI. `adapter/driver_install_win.rs`
calls `SetupDi*`, `DiInstallDriverW` and `Cert*` directly through the `windows`
crate.

## Looking at the UI instead of shipping it unseen

`opends-app/hack/shot.ps1` captures the screen from WSL. Use it. Three real bugs
shipped into a build that was never looked at: the progress card was clipped off
the bottom, the Install button was half off screen, and two labels still said
`opends` after the rename.

Two things make the capture possible.

**A `requireAdministrator` exe cannot be launched from WSL interop.** The symptom
is `Invalid argument`, which looks exactly like a Smart App Control block and is
not one. Build with `OPENDS_NO_MANIFEST=1` to get a launchable copy for looking
at the UI. I burned four rebuilds blaming SAC before testing that.

**Never click by computing screen coordinates.** `GetWindowRect` returns physical
pixels and the capture is scaled, so a click lands somewhere else. `--self-test`
starts the install on the first frame with no pointer involved. That is the
deterministic way to photograph the running and failed states.

## OpenDS.exe has a GUI now, and it needs no manifest at all

`OpenDS.exe` was CLI-only. It now defaults to a small egui/eframe window
(`opends-app/src/driver/app_gui.rs`) showing which pad is connected, its
transport, its battery, and whether the virtual pad is active, with a real
Win32 tray icon (`opends-app/src/adapter/tray_adapter.rs`, raw
`Shell_NotifyIconW`, no new crate). Double-clicking the exe with no arguments
launches the GUI. Every existing flag still works unchanged from a terminal,
including a new explicit `--gui`.

`OpenDS.exe` picked up `windows_subsystem = "windows"` to match, so a
double-click no longer flashes a black console window. `console_adapter::attach`
already existed to reattach a terminal's stdout when one is present, exactly
the trap this file already documents further down — `OpenDS-Setup.exe` was
already windows-subsystem and this just brings `OpenDS.exe` in line.

**The build.rs manifest embed only ever targeted `OpenDS-Setup`, not
`OpenDS`.** `cargo:rustc-link-arg-bin=OpenDS-Setup=...` names the bin
explicitly. So `OpenDS.exe` has never needed `requireAdministrator` or
`OPENDS_NO_MANIFEST=1` to be WSL-launchable — it was always launchable, the
same way `--probe` already was for the installer. Verified by actually
launching the freshly built exe straight from WSL with no elevation, no
`OPENDS_NO_MANIFEST`, and screenshotting the real window: title "OpenDS",
correct status text, no clipping. `Get-Process ... MainWindowHandle` plus
`SetForegroundWindow`/`ShowWindow` from a tiny inline C# type was what got it
in front of the capture — `Start-Process` alone is not enough when another
window already has focus, the screenshot just shows whatever is on top.

Closing the window hides it to the tray (`ViewportCommand::CancelClose` then
`Visible(false)`) rather than exiting. Only the tray's Quit item, or killing
the process, actually ends it.

## SetForegroundWindow from a WSL-launched process silently does nothing

Worked once, then stopped working across several later screenshot attempts in
the same session, capturing an unrelated terminal tab instead of `OpenDS`
every time, even though `Get-Process` showed the right `MainWindowHandle` and
the call itself reported no error. Windows restricts which process is allowed
to steal foreground focus, and a `powershell.exe` freshly spawned through WSL
interop does not hold that permission, so `SetForegroundWindow` returns
without doing anything and the screenshot silently captures whatever already
had focus. Nothing about that failure is visible from the call site.

Fixed by not depending on focus at all. `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`
captures a specific window's contents directly from its handle, regardless of
z-order or which window is focused. `PW_RENDERFULLCONTENT` (flag value `2`)
is required for GPU-composited content; the plain flag renders black for an
eframe/glow window. Get the real size from `GetWindowRect` first rather than
assuming the logical size passed to `MoveWindow`, since DPI scaling can make
those differ.

## An in-place rebuild of a Windows exe is not reliably picked up

`cargo build --target x86_64-pc-windows-gnu --tests` writes the test harness
to the same filename every time, since the hash cargo picks is derived from
crate metadata, not content. Touched the source, rebuilt, ran the exe: it
kept running the OLD test body, under the OLD test name, even though `strings`
on the very same file confirmed the new name was the only one present in the
bytes on disk. Reproduced identically three ways: WSL binfmt launch, and
`powershell.exe` given the `\\wsl.localhost\...` path directly. Not a build
cache problem, not a Bash tool output buffering illusion, checked both.

Fixed by deleting the file before rebuilding rather than letting `cargo`
overwrite it in place. The next build produced a normal-looking "Finished"
in about the same time, and the freshly-written file ran the new test
correctly on the first try. Windows appears to cache the mapped executable
image by file identity across the WSL/9p filesystem boundary in a way an
in-place content overwrite does not reliably invalidate, so a `.exe`
executed from a WSL path can silently keep running stale code after a
rebuild that reports success. If a test result looks like it belongs to a
version of the code you already changed, delete the exe and rebuild before
trusting the result.

**This is not a hypothetical edge case, `forge test-all`'s own `unit-windows`
stage hit it for real**, reporting `✅ Stage 'unit-windows' passed` while
the earlier report already showed the exact panic from a test whose
assertion had since been fixed. `opends-app/hack/unit-windows.sh` now
deletes `target/x86_64-pc-windows-gnu/debug/deps/opends_app-*.exe` before
running `cargo test`, and `forge.yaml`'s `unit-windows` stage runs that
script instead of calling `cargo test` directly. Confirmed the fix by
reproducing the staleness on demand (rename a test, rebuild in place, watch
the old name still run and fail) and then confirming a deleted-first rebuild
picks up the rename correctly, three times in a row.

## Windows traps

**A windows subsystem exe has no stdout.** `AttachConsole` alone is not enough.
`GetStdHandle` still returns nothing. Open `CONOUT$` then `SetStdHandle`. And
skip attaching when a handle is already set, or a `> file` redirect is
overwritten by the console and the file stays empty.

**A `HANDLE` is neither `Send` nor `Sync`.** The Linux build never notices
because the HID code is `cfg(windows)`. Only the cross build catches it.

**Bluetooth writes carry a CRC32.** A wrong CRC means the pad ignores every
write and says nothing at all.

**The parse belongs in core, not the adapter.** The architecture stage refuses
one adapter importing another, and splitting HID transport from Sony decoding
into two adapter files breaks that rule. The decoding is pure so it goes to
core.

## Editing traps

**A scripted string replace that does not match fails silently.** `cargo fmt`
runs in the `format-code` build step and reflows what you were about to match.
Grep for the new text after every scripted edit.

**Commit before a wide edit.** An over wide slice deletes things and
`git show HEAD:<path>` is the only cheap way back.

**No comments in code.** Zero. The reason goes in a test name or in `docs/`.
