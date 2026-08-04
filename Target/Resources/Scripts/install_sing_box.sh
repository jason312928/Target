#!/bin/sh
set -eu

version="1.13.16"
base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
support_dir="${HOME}/Library/Application Support/Target/sing-box"

case "$(uname -m)" in
  arm64)
    archive_name="sing-box-${version}-darwin-arm64.tar.gz"
    archive_sha256="32fa21fd75ad62d86a2dcb7e0be77359c35e12798cdbb6a0e30654ef487d90d6"
    ;;
  x86_64)
    archive_name="sing-box-${version}-darwin-amd64.tar.gz"
    archive_sha256="2bfad58d034e280c773e194be03649555e5a7040c48b559dd0898ad293fe793d"
    ;;
  *)
    echo "Unsupported macOS architecture." >&2
    exit 1
    ;;
esac

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/target-sing-box.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
archive_path="$work_dir/$archive_name"

curl --fail --location --proto '=https' --tlsv1.2 --output "$archive_path" "$base_url/$archive_name"
actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
if [ "$actual_sha256" != "$archive_sha256" ]; then
  echo "sing-box archive checksum verification failed." >&2
  exit 1
fi

tar -xzf "$archive_path" -C "$work_dir"
binary_path="$work_dir/sing-box-${version}-darwin-$( [ "$(uname -m)" = arm64 ] && printf arm64 || printf amd64 )/sing-box"
if [ ! -x "$binary_path" ]; then
  echo "Downloaded archive did not contain the expected sing-box executable." >&2
  exit 1
fi

mkdir -p "$support_dir/bin"
install -m 755 "$binary_path" "$support_dir/bin/sing-box"
"$support_dir/bin/sing-box" version | grep -F "sing-box version ${version}" >/dev/null
