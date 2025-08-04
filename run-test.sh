#!/bin/bash
set -exuo pipefail

ARCH=$(uname -m)

BOOTC_TEMPDIR=$(mktemp -d)
trap 'rm -rf -- "$BOOTC_TEMPDIR"' EXIT

TEST_IMAGE_URL="quay.io/centos-bootc/centos-bootc:stream10"

SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=${BOOTC_TEMPDIR}/id_rsa
ssh-keygen -f "${SSH_KEY}" -N "" -q -t rsa-sha2-256 -b 2048

sudo truncate -s 10G "${BOOTC_TEMPDIR}/disk.raw"

sudo podman run \
  --rm \
  --privileged \
  --pid=host \
  --tls-verify=false \
  --security-opt label=type:unconfined_t \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev \
  -v "$BOOTC_TEMPDIR":/output \
  "$TEST_IMAGE_URL" \
  bootc install to-disk \
  --filesystem "xfs" \
  --root-ssh-authorized-keys "/output/id_rsa.pub" \
  --karg=console=ttyS0,115200 \
  --generic-image \
  --via-loopback \
  /output/disk.raw

case "$ARCH" in
"aarch64")
  sudo qemu-system-aarch64 \
    -name bootc-vm \
    -enable-kvm \
    -machine virt \
    -cpu host \
    -m 2G \
    -bios /usr/share/AAVMF/AAVMF_CODE.fd \
    -drive file="${BOOTC_TEMPDIR}/disk.raw",if=virtio,format=raw \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -display none \
    -daemonize
  ;;
"x86_64")
  sudo qemu-system-x86_64 \
    -name bootc-vm \
    -enable-kvm \
    -cpu host \
    -m 2G \
    -drive file="${BOOTC_TEMPDIR}/disk.raw",if=virtio,format=raw \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::2222-:22 \
    -display none \
    -daemonize
  ;;
*)
  redprint "Only support x86_64 and aarch64"
  exit 1
  ;;
esac

wait_for_ssh_up() {
  SSH_STATUS=$(ssh "${SSH_OPTIONS[@]}" -i "${BOOTC_TEMPDIR}/id_rsa" -p 2222 root@"${1}" '/bin/bash -c "echo -n READY"')
  if [[ $SSH_STATUS == READY ]]; then
    echo 1
  else
    echo 0
  fi
}

for _ in $(seq 0 30); do
  RESULT=$(wait_for_ssh_up "localhost")
  if [[ $RESULT == 1 ]]; then
    echo "SSH is ready now! 🥳"
    break
  fi
  sleep 10
done

ssh "${SSH_OPTIONS[@]}" \
  -i "${BOOTC_TEMPDIR}/id_rsa" \
  -p 2222 \
  root@localhost \
  "bootc status"
