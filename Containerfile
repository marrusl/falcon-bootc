# Base image. Override to build on RHEL 10:
#   --build-arg BASE_IMAGE=registry.redhat.io/rhel10/rhel-bootc:latest
#   --build-arg BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream9
# Tracks latest rather than pinning a minor version; see README.
ARG BASE_IMAGE=registry.redhat.io/rhel9/rhel-bootc:latest
FROM ${BASE_IMAGE}

ARG FALCON_CID

COPY assets /tmp/assets

RUN <<EOF
set -euxo pipefail

# install falcon sensor
rpm --import /tmp/assets/*.gpg
dnf -y install /tmp/assets/*.rpm

# /opt is read-only in a bootc deployment. Make just this directory writable
# with a state overlay rather than relocating the tree to /var, where the
# payload would stop tracking the image. Scoped to /opt/CrowdStrike: do not
# use @opt.service, which makes all of /opt writable.
#
# Needs RHEL 9.6 or later. Changes this directory's mode and SELinux label,
# which affects non-root access: see README. Rationale and testing in
# DESIGN.md. man:ostree-state-overlay@.service(8).
systemctl enable 'ostree-state-overlay@opt-CrowdStrike.service'

# workaround: allow service to restart briefly on failure (fatal issue where pidfile can't be created on first boot)
sed -i 's/\[Unit\]/\[Unit\]\nStartLimitIntervalSec=10/' /usr/lib/systemd/system/falcon-sensor.service
sed -i 's/\[Unit\]/\[Unit\]\nStartLimitBurst=3/' /usr/lib/systemd/system/falcon-sensor.service
sed -i 's/Restart=no/Restart=on-failure/' /usr/lib/systemd/system/falcon-sensor.service

# workaround: disable proxy (nonfatal issue where falcon logs "Could not retrieve DisableProxy value")
/opt/CrowdStrike/falconctl -s --apd=true

# configure and enable sensor
/opt/CrowdStrike/falconctl -s --cid=$FALCON_CID
systemctl enable falcon-sensor

# cleanup
dnf clean all
echo FALCON-BOOTC-COMPLETE

EOF
