# Why a state overlay instead of relocating to /var

Design notes for this branch. The README covers what an operator adopting the recipe needs;
this file is the case for the approach, written for anyone deciding whether it is sound.

Summary: the published recipe moves the whole `/opt/CrowdStrike` tree into `/var/opt`. That
makes the directory writable, which is the right goal, but it has the side effect that the
sensor payload stops tracking the image. This branch leaves the payload where the RPM puts
it and makes just that directory writable with an ostree state overlay instead.

## The problem with /var placement

Content that a container image places in `/var` is applied only when a system is first
installed, and is never refreshed by `bootc upgrade` or `bootc switch`. This is documented
upstream behavior, not a bug: `/var` is treated like a Docker volume, so that application
data is not rolled back when the operating system is.

Applied to a relocated sensor tree, that means a host keeps its install-day binaries no
matter how many new images are built and shipped. Meanwhile the `falcon-sensor.service` unit
that this Containerfile patches, the SELinux policy, and the kernel all come from the image
and are replaced on every update. The two halves drift apart with nothing to reconcile them.

`bootc rollback` does not fix it, because `/var` is shared across deployments and does not
roll back. Roll back after a cloud-pushed sensor update and you get the old kernel, the old
unit file, and the new sensor. No sequence of bootc commands puts that pair back together,
and the combination actually running on the host is not reproducible from any registry,
which makes it hard for anyone to support.

`bootc container lint` already flags the relocation layout, under `var-tmpfiles` and
"non-directory files in /var". It does not flag the overlay layout.

## What the current approach gets right

Two things, both kept by this branch.

The agent ID is handled correctly. `falconstore` lands in `/var`, which is machine-local and
persistent, and the build never starts the sensor, so no agent ID is baked into the image
and each host enrolls its own on first boot. That is the hardest thing to get right when
putting an enrolling agent into a shared image, and the recipe gets it right.

The `/var` placement also preserves the cloud update path, which is a real argument for it.
A kernel-mode sensor that falls behind a new kernel can be fixed from the cloud without an
image rebuild. Any replacement has to keep that working, which is why question 1 below is
the one that matters.

## What a state overlay does instead

```
systemctl enable 'ostree-state-overlay@opt-CrowdStrike.service'
```

The overlay's upper layer lives in `/var` and survives reboots, so the directory is writable
and its contents persist. On the first boot into a different deployment, ostree walks the
upper and applies one rule: entries that shadow a file the image ships are deleted, entries
that exist only in the upper are kept. Whiteouts count as shadowing, so deleting an
image-shipped file is also undone.

Mapped onto the sensor directory, every object lands where it should:

| Object | In the image | Behavior on upgrade, switch or rollback |
|---|---|---|
| `falconstore` (agent ID) | no, created at first boot | kept |
| `KernelModuleArchiveExt*` (cloud channel files) | no, cloud-delivered | kept |
| `falcon-sensor` symlink | yes | reverts to the image's target |
| `KernelModuleArchive` | yes | reverts to the image's version |
| Self-updated versioned binaries | no, new filename | kept, see caveats |

So machine identity and cloud-delivered content persist, while the binaries track the image.
A rollback produces a matching pair for the first time.

See `man:ostree-state-overlay@.service(8)` for the upstream description.

## What changes operationally

Less than it first appears, and it is worth being precise about what is actually different.

The sensor version comes from the image. After an OS upgrade a host runs the sensor the image
was built with, and the host's sensor update policy then moves it to the policy version on the
next check-in, the same way it does for any host found running the wrong version. Policies move
hosts in both directions, so this is the mechanism working normally.

**The running version therefore converges where it already does today.** What changes is the
starting point: the image sets it on every upgrade, rather than install day setting it once and
permanently. That is the whole of the difference, and it is the point of the change, because
under `/var` nothing ever re-establishes a known version.

What is genuinely new, and it is small: each correction costs a sensor restart, and there is a
window between boot and the next check-in during which the host runs the image's sensor.
CrowdStrike does not publish a check-in interval for the Linux host sensor, so the length of
that window is not something we can state. Under a policy set to sensor version updates off
there is no correction and no restart, which is also the configuration this approach suits best.

**All of it is conditional on question 1.** The correction has to write into the overlay upper
to happen at all. If the updater cannot do that, cloud updates do not work under this design
and the approach does not hold.

### Why the instance is scoped

The unit's instance name is a systemd-escaped path, so `@opt-CrowdStrike` resolves to
`ostree admin state-overlay opt-CrowdStrike /opt/CrowdStrike` and covers that directory
alone. The more commonly published `@opt.service` would make the entire `/opt` namespace
writable, including any subtree another vendor installs later, for no benefit here.

Scoping also keeps the writable surface no larger than the `/var/opt` relocation already
exposes, while restoring something the relocation gives up: the image-shipped copy of the
sensor stays inside the measured image, so there is a baseline to revert to.

### Not supported on the native composefs backend

**`bootc install --composefs-backend` produces a host where the overlay never mounts, and
nothing reports it.** Verified by boot test on RHEL 10.2 (`bootc-1.16.4`): the install
succeeds, the host boots normally, and `/opt/CrowdStrike` stays read-only. A real sensor
would fail at runtime trying to write `falconstore`.

The cause is in the unit, not in this recipe. `ostree-state-overlay@.service` carries
`ConditionKernelCommandLine=ostree`, and the native composefs backend boots with
`composefs=<digest>` and no `ostree=` argument, so systemd skips the unit. The journal shows
"skipped because of an unmet condition check" and `systemctl is-active` reports `inactive`
rather than `failed`, so there is no failure signal.

It is not a one-line fix either. `ostree admin state-overlay` bails with "Must be booted into
an OSTree deployment" when there is no booted ostree deployment, and the prune keys on the
deployment checksum, which has no equivalent on a native composefs boot.

This matters because the native composefs backend is what sealed images require, and
logically bound images have the same gap (`bootc-dev/bootc#2540`). So the two mechanisms for
getting a host agent onto a bootc system are both unavailable on the backend that sealing
needs. Note the asymmetry is structural as well as incidental: sealing wants the agent
directory measured and read-only, and a self-updating agent needs it writable.

On the default ostree backend with composefs enabled, which is the recommended baseline and
what most systems run, everything in this document applies.

### Integrity, and what is measured

On the ostree backend the overlay's contents are not covered by fs-verity, because the upper
layer lives in `/var`. The image-shipped copy underneath it is measured, which is the point:
it gives a baseline the prune restores. On the native composefs backend the question does not
arise, since no overlay mounts and the directory stays fully inside the measured image.

### Do not combine with a transient root

The composefs root is already an overlay, so a state overlay is a second layer and a
transient root would add a third, past the kernel's `FILESYSTEM_MAX_STACK_DEPTH`. That
combination is untested; assume it fails.

## What was tested

Boot-tested on both ends of the supported range, each installed with `bcvk to-disk` and
booted under KVM across real reboots. RHEL 9.6 EUS (`ostree-2025.2-4.el9_6`, `bootc-1.1.6`)
as the oldest base anyone would use, and RHEL 10.2 (`ostree-2025.7-1.el10`, `bootc-1.16.4`)
as the current RHEL 10. Results were identical on both. A stand-in payload stood in for the
sensor.

- The unit comes up active on first boot, `/opt/CrowdStrike` is an overlay mount, and `/opt`
  itself is not a mount. `/opt` and a second vendor directory alongside it stayed read-only
  on the running system. SELinux enforcing, no denials from the overlay.
- The prune rule across `bootc switch`: overwrites of image-shipped files reverted to the
  new image's content, a repointed image-shipped symlink reverted, a deleted image file came
  back, and files that existed only in the overlay survived untouched.
- `bootc rollback` behaves the same way, because a rollback is also a deployment change.
- `/opt` is a real read-only directory in a bootc deployment, not a symlink to `/var/opt`,
  and it is `usr_t` on both RHEL 9 and RHEL 10, so no `semanage` is needed.

## Two verified side effects

The merged directory takes its mode, owner and SELinux label from the overlay's upper
directory rather than from the image. ostree creates that upper with mode 0700, so
`/opt/CrowdStrike` appears as `drwx------` root and `var_t` once mounted, instead of the
`drwxr-xr-x` `usr_t` the image ships. A non-root process gets `Permission denied` just
listing it. A `chmod 0755` on the merged directory after mount should fix it, and has not
been tested.

Files created inside the overlay get `var_t`, while files inherited from the image keep
`usr_t`, including after a copy-up write. No denials appeared in testing, but the test
payload was a shell script rather than a confined daemon.

## Caveats even if the approach holds

A local edit to any file the image ships is reverted on the next deployment change with
nothing logged. State overlays have no equivalent of `ostree admin config-diff`, so there is
no way to see what is in the upper or what is about to be reverted. This one is a real
difference rather than a pre-existing condition: under `/var` the same edit persists
indefinitely, which is the frozen-payload problem wearing a different hat. Reverted silently
is still worse than reverted loudly, and the missing introspection is worth raising upstream
with ostree independently of anything here.

### Stale versioned binaries are not an additional cost

Named because it looks like one. The sensor keeps version-stamped binaries and third-party
write-ups going back to 2019 report that old versions are never removed, so they accumulate on
any host and accumulate identically under `/var`, where nothing prunes anything. Under the
overlay an orphaned copy is additionally reclaimed once an image ships that same version.

## Open questions, which need CrowdStrike

None of this has been run with a real Falcon sensor. Three questions decide whether the
approach actually works:

1. **Does the sensor updater work correctly when its target directory is an overlayfs upper**
   rather than a plain filesystem, in particular if it renames over an existing file, which
   overlayfs handles differently because of copy-up? This is the hinge. Whether cloud updates
   work at all under this design, and whether a host that has drifted self-heals, both depend
   on it. If the answer is no, the approach does not hold.

   The related product question, where there is a proposed answer rather than an open one:
   when the image's version and the cloud's disagree, the image should win, with the customer
   keeping their build inputs current. If the cloud must always win instead, the containerized
   sensor is the better answer for these hosts.
2. Does the sensor tolerate its install directory being mode 0700 and owned by root?
3. Does the sensor care if files it creates carry `var_t` rather than `usr_t`?

Related, and unverifiable from outside: every claim in the mapping table above follows from
the verified prune rule applied to the documented directory layout, but no sensor was run
against it.

## Version requirement

The overlay works on RHEL 9.6 and later, and on RHEL 10. The dependency is the backport of
`ostreedev/ostree#3555`, without which the overlay fails to mount on first boot with
`lgetxattr(user.ostree.deploymentcsum): No data available`. Verified by reading
`rpm -q --changelog ostree` in each image:

| Image | `ostree` | Backport |
|---|---|---|
| `rhel9/rhel-bootc:9.6` (out of support) | `2025.2-2.el9_6` | no |
| `rhel9-eus/rhel-9.6-bootc` | `2025.2-4.el9_6` | yes (RHEL-143220) |
| `rhel9/rhel-bootc:9.7` | `2025.6-2.el9_7` | yes (RHEL-143221) |
| `rhel9/rhel-bootc:9.8` | `2025.7-1.el9` | yes (RHEL-129049) |
| RHEL 10 | any | not applicable, never affected |

The only image lacking it is the out-of-support mainline 9.6 tag, which is also what this
repository used to pin. That is why the base image moved here as well as on its own branch:
the overlay could not have worked on the base the branch inherited, and no `dnf update` in
the build could have rescued it, because an out-of-support minor stops receiving repository
updates. The EUS build of the same minor version does carry the backport.

Tracking the latest supported minor rather than pinning one is the general fix. A pinned
minor ages out quietly, which is how this repository ended up on an unsupported base.
