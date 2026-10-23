<p align="center">
   <img src="img/crowdstrike.png" alt="CrowdStrike logo" width="500"/>
</p>

# falcon-bootc

Configuration for creating a bootc-based image with the Falcon sensor installed.

This is an example that users should adapt to their bootc workflow. The resulting image will be
associated with a specific customer ID (CID). Upon startup, the host will generate a new agent ID (AID).

## About this branch

This branch makes `/opt/CrowdStrike` writable with an ostree state overlay instead of
relocating the tree into `/var/opt`. The sensor's agent ID and its cloud-delivered kernel
module channel files persist as before; the sensor binaries now track the image, so a host
that takes a new image gets the sensor version that image was built with.

**This has not been run with a real Falcon sensor.** The overlay itself is boot-tested on
RHEL 9.6 EUS and RHEL 10.2, but whether a cloud-pushed sensor update behaves correctly in an
overlay is an open question. Treat it as a proposal, not a supported configuration.

See [DESIGN.md](DESIGN.md) for why this approach, what was tested, and the open questions.

### What you need to know to run it

- **Requires RHEL 9.6 or later, or RHEL 10.** Earlier RHEL 9 builds lack an ostree fix
  without which the overlay does not mount. On 9.6, use the EUS image.
- **`/opt/CrowdStrike` becomes root-only.** The overlay changes the directory to mode 0700
  owned by root, so processes that are not root can no longer read it. The sensor runs as
  root and is unaffected, but a log shipper, backup job or monitoring agent that reads that
  path will start failing. Check before deploying.
- Everything else under `/opt` stays read-only. The overlay is scoped to the sensor's own
  directory.
- **Do not install with `--composefs-backend`.** On the native composefs backend the overlay
  never mounts, `/opt/CrowdStrike` stays read-only, and nothing reports it, so the sensor
  fails at runtime instead of at install. The default ostree backend is what this needs. See
  [DESIGN.md](DESIGN.md).
- Local edits to files that came from the image are reverted when the host boots into a new
  image, without a log entry. Put anything you need to keep somewhere else.
- **The image sets the sensor version at each upgrade.** After an OS upgrade the host runs
  the sensor the image was built with, and your sensor update policy then moves it to the
  policy version on the next check-in, as it would for any host. The running version ends up
  where it does today; the difference is that the image sets the starting point. Each
  correction costs a sensor restart, so keeping the RPM in your build inputs current avoids
  the churn.

## Support

falcon-bootc is an open source project, not a CrowdStrike product. As such, it carries no formal support, expressed or implied.

## Prerequisites

### RHEL setup

1. Install Podman
2. Log in to the Red Hat registry:

```bash
podman login registry.redhat.io
# enter your Red Hat login
```

### Mac setup

1. Install Podman
2. Create a Podman machine with rootful and a volume mount:

```bash
podman machine init --rootful -v $HOME/projects:$HOME/projects
```

3. Log in to the Red Hat registry:

```bash
podman login registry.redhat.io
# enter your Red Hat login
```

4. Register the Podman machine so it has access to subscription content (don't copy and paste both commands into the terminal, you need to start the SSH session _then_ register):

```bash
podman machine ssh
# then inside the ssh session...
subscription-manager register
# enter your Red Hat login
```

## Building

The `Containerfile` builds against a RHEL 9 base by default. A RHEL 10 base also works:
change the `FROM` line. The SELinux relabeling step is skipped automatically on RHEL 10,
where the distro policy already equates `/var/opt` with `/opt`.

1. Download a GPG key and RPM that matches the system's architecture and place them in `assets`. Note: the `Containerfile` installs any `*.gpg` and `*.rpm` file found, so ensure the files match this convention.
2. Retrieve your CID and set as as environment variable: `FALCON_CID=abcd1234`
3. Build the container image: `podman build --build-arg FALCON_CID=$FALCON_CID -t falcon-bootc-demo:latest .`
   To build against RHEL 10 instead of the default RHEL 9, add
   `--build-arg BASE_IMAGE=registry.redhat.io/rhel10/rhel-bootc:latest`. The base tracks the
   latest supported minor rather than pinning one, so it does not quietly age out of
   support; if you must stay on a specific older minor, use that release's EUS image.
4. Build the bootable image:

```
podman run \
  --rm \
  --privileged \
  --pull=newer \
  --security-opt label=type:unconfined_t \
  -v ./config.toml:/config.toml \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  registry.redhat.io/rhel9/bootc-image-builder:latest \
  --type iso \
  --config /config.toml \
  --local=true \
  localhost/falcon-bootc-demo:latest
```

5. Launch a VM with the ISO as the boot disk.
