#!/bin/bash

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. "$(dirname "$0")/common.sh"

set -e

# Print usage string
usage() {
  cat <<EOF
Usage: $PROG /path/to/cros_root_fs/dir /path/to/keys/dir

Re-sign framework apks in an Android system image.  The image itself does not
need to be signed since it is shipped with Chrome OS image, which is already
signed.

Android has many "framework apks" that are signed with 4 different framework
keys, depends on the purpose of the apk.  During development, apks are signed
with the debug one.  This script is to re-sign those apks with corresponding
release key.  It also handles some of the consequences of the key changes, such
as sepolicy update.

EOF
  if [[ $# -gt 0 ]]; then
    error "$*"
    exit 1
  fi
  exit 0
}

# Return name according to the current signing debug key. The name is used to
# select key files.
choose_key() {
  local sha1="$1"
  local keyset="$2"

  if [[ "${keyset}" != "aosp" && "${keyset}" != "cheets" ]]; then
    error "Unknown Android build keyset '${keyset}'"
    return 1
  fi

  # Fingerprints below are generated by:
  # 'cheets' keyset:
  # $ keytool -file vendor/google/certs/cheetskeys/$NAME.x509.pem -printcert \
  #     | grep SHA1:
  # 'aosp' keyset:
  # $ keytool -file build/target/product/security/$NAME.x509.pem -printcert \
  #     | grep SHA1:
  declare -A platform_sha=(
    ['cheets']='AA:04:E0:5F:82:9C:7E:D1:B9:F8:FC:99:6C:5A:54:43:83:D9:F5:BC'
    ['aosp']='27:19:6E:38:6B:87:5E:76:AD:F7:00:E7:EA:84:E4:C6:EE:E3:3D:FA'
  )
  declare -A media_sha=(
    ['cheets']='D4:C4:2D:E0:B9:1B:15:72:FA:7D:A7:21:E0:A6:09:94:B4:4C:B5:AE'
    ['aosp']='B7:9D:F4:A8:2E:90:B5:7E:A7:65:25:AB:70:37:AB:23:8A:42:F5:D3'
  )
  declare -A shared_sha=(
    ['cheets']='38:B6:2C:E1:75:98:E3:E1:1C:CC:F6:6B:83:BB:97:0E:2D:40:6C:AE'
    ['aosp']='5B:36:8C:FF:2D:A2:68:69:96:BC:95:EA:C1:90:EA:A4:F5:63:0F:E5'
  )
  declare -A release_sha=(
    ['cheets']='EC:63:36:20:23:B7:CB:66:18:70:D3:39:3C:A9:AE:7E:EF:A9:32:42'
    ['aosp']='61:ED:37:7E:85:D3:86:A8:DF:EE:6B:86:4B:D8:5B:0B:FA:A5:AF:81'
  )

  case "${sha1}" in
    "${platform_sha["${keyset}"]}")
      echo "platform"
      ;;
    "${media_sha["${keyset}"]}")
      echo "media"
      ;;
    "${shared_sha["${keyset}"]}")
      echo "shared"
      ;;
    "${release_sha["${keyset}"]}")
      # The release_sha[] fingerprint is from devkey. Translate to releasekey.
      echo "releasekey"
      ;;
    *)
      # Not a framework apk.  Do not re-sign.
      echo ""
      ;;
  esac
  return 0
}

# Re-sign framework apks with the corresponding release keys.  Only apk with
# known key fingerprint are re-signed.  We should not re-sign non-framework
# apks.
sign_framework_apks() {
  local system_mnt="$1"
  local key_dir="$2"
  local flavor_prop=""
  local keyset=""

  # Property ro.build.flavor follows those patterns:
  # - cheets builds:
  #   ro.build.flavor=cheets_${arch}-user(debug)
  # - SDK builds:
  #   ro.build.flavor=sdk_google_cheets_${arch}-user(debug)
  # - AOSP builds:
  #   ro.build.flavor=aosp_cheets_${arch}-user(debug)
  # "cheets" and "SDK" builds both use the same signing keys, cheetskeys. "AOSP"
  # builds use the public AOSP signing keys.
  flavor_prop=$(grep -a "^ro\.build\.flavor=" \
    "${system_mnt}/system/build.prop" | cut -d "=" -f2)

  info "Found build flavor property '${flavor_prop}'."
  if [[ "${flavor_prop}" == aosp_cheets_* ]]; then
    keyset="aosp"
  elif [[ "${flavor_prop}" == cheets_* ||
    "${flavor_prop}" == sdk_google_cheets_* ]]; then
    keyset="cheets"
  else
    die "Unknown build flavor property '${flavor_prop}'."
  fi
  info "Expecting signing keyset '${keyset}'."

  info "Start signing framework apks"

  # Counters for sanity check.
  local counter_platform=0
  local counter_media=0
  local counter_shared=0
  local counter_releasekey=0
  local counter_total=0

  local apk
  while read -d $'\0' -r apk; do
    local sha1=""
    local keyname=""

    sha1=$(unzip -p "${apk}" META-INF/CERT.RSA | \
      keytool -printcert | awk '/^\s*SHA1:/ {print $2}')

    if  ! keyname=$(choose_key "${sha1}" "${keyset}"); then
      die "Failed to choose signing key for APK '${apk}' (SHA1 '${sha1}') in \
build flavor '${flavor_prop}'."
    fi
    if [[ -z "${keyname}" ]]; then
      continue
    fi

    info "Re-signing (${keyname}) ${apk}"

    local temp_dir="$(make_temp_dir)"
    local temp_apk="${temp_dir}/temp.apk"
    local signed_apk="${temp_dir}/signed.apk"
    local aligned_apk="${temp_dir}/aligned.apk"

    # Follow the standard manual signing process.  See
    # https://developer.android.com/studio/publish/app-signing.html.
    cp -a "${apk}" "${temp_apk}"
    # Explicitly remove existing signature.
    zip -q "${temp_apk}" -d "META-INF/*"
    signapk "${key_dir}/$keyname.x509.pem" "${key_dir}/$keyname.pk8" \
        "${temp_apk}" "${signed_apk}" > /dev/null
    zipalign 4 "${signed_apk}" "${aligned_apk}"

    # Copy the content instead of mv to avoid owner/mode changes.
    sudo cp "${aligned_apk}" "${apk}" && rm -f "${aligned_apk}"

    : $(( counter_${keyname} += 1 ))
    : $(( counter_total += 1 ))
  done < <(find "${system_mnt}/system" -type f -name '*.apk' -print0)

  info "Found ${counter_platform} platform APKs."
  info "Found ${counter_media} media APKs."
  info "Found ${counter_shared} shared APKs."
  info "Found ${counter_releasekey} release APKs."
  info "Found ${counter_total} total APKs."
  # Sanity check.
  if [[ ${counter_platform} -lt 2 || ${counter_media} -lt 2 ||
        ${counter_shared} -lt 2 || ${counter_releasekey} -lt 2 ||
        ${counter_total} -lt 25 ]]; then
    die "Number of re-signed package seems to be wrong"
  fi
}

# Platform key is part of the SELinux policy.  Since we are re-signing framework
# apks, we need to replace the key in the policy as well.
update_sepolicy() {
  local system_mnt=$1
  local key_dir=$2

  # Only platform is used at this time.
  local public_platform_key="${key_dir}/platform.x509.pem"

  info "Start updating sepolicy"

  local new_cert=$(sed -E '/(BEGIN|END) CERTIFICATE/d' \
    "${public_platform_key}" | tr -d '\n' \
    | base64 --decode | hexdump -v -e '/1 "%02x"')

  if [[ -z "${new_cert}" ]]; then
    die "Unable to get the public platform key"
  fi

  shopt -s nullglob
  local xml_list=( "${system_mnt}"/system/etc/**/*mac_permissions.xml )
  shopt -u nullglob
  if [[ "${#xml_list[@]}" -ne 1 ]]; then
    die "Unexpected number of *mac_permissions.xml: ${#xml_list[@]}\n \
      ${xml_list[*]}"
  fi

  local xml="${xml_list[0]}"
  local orig=$(make_temp_file)
  local pattern='(<signer signature=")\w+("><seinfo value="platform)'
  cp "${xml}" "${orig}"
  sudo sed -i -E "s/${pattern}/\1${new_cert}"'\2/g' "${xml}"

  # Sanity check.
  if cmp "${xml}" "${orig}"; then
    die "Failed to replace SELinux policy cert"
  fi
}

# Replace the debug key in OTA cert with release key.
replace_ota_cert() {
  local system_mnt=$1
  local release_cert=$2
  local ota_zip="${system_mnt}/system/etc/security/otacerts.zip"

  info "Replacing OTA cert"

  local temp_dir=$(make_temp_dir)
  pushd "${temp_dir}" > /dev/null
  cp "${release_cert}" .
  local temp_zip=$(make_temp_file)
  zip -q -r "${temp_zip}.zip" .
  # Copy the content instead of mv to avoid owner/mode changes.
  sudo cp "${temp_zip}.zip" "${ota_zip}"
  popd > /dev/null
}

# Restore SELinux context.  This has to run after all file changes, before
# creating the new squashfs image.
reapply_file_security_context() {
  local system_mnt=$1
  local root_fs_dir=$2

  info "Reapplying file security context"

  sudo /sbin/setfiles -v -r "${system_mnt}" \
      "${root_fs_dir}/etc/selinux/arc/contexts/files/android_file_contexts" \
      "${system_mnt}"
}

# Snapshot file properties in a directory recursively.
snapshot_file_properties() {
  local dir=$1
  sudo find "${dir}" -exec stat -c '%n:%u:%g:%a:%C' {} + | sort
}

main() {
  local root_fs_dir=$1
  local key_dir=$2
  local android_dir="${root_fs_dir}/opt/google/containers/android"
  local system_img="${android_dir}/system.raw.img"
  # Use the versions in $PATH rather than the system ones.
  local unsquashfs=$(which unsquashfs)
  local mksquashfs=$(which mksquashfs)

  if [[ $# -ne 2 ]]; then
    usage "command takes exactly 2 args"
  fi

  if [[ ! -f "${system_img}" ]]; then
    die "System image does not exist: ${system_img}"
  fi

  if ! type -P zipalign &>/dev/null || ! type -P signapk &>/dev/null; then
    # TODO(victorhsieh): Make this an error.  This is not treating as error
    # just to make an unrelated test pass by skipping this signing.
    warn "Skip signing Android apks (some of executables are not found)."
    exit 0
  fi

  local working_dir=$(make_temp_dir)
  local system_mnt="${working_dir}/mnt"
  local compression_method=$(sudo unsquashfs -s "${system_img}" | \
      awk '$1 == "Compression" { print $2 }')

  info "Unpacking squashfs image to ${system_img}"
  sudo "${unsquashfs}" -x -f -no-progress -d "${system_mnt}" "${system_img}"

  snapshot_file_properties "${system_mnt}" > "${working_dir}/properties.orig"

  sign_framework_apks "${system_mnt}" "${key_dir}"
  update_sepolicy "${system_mnt}" "${key_dir}"
  replace_ota_cert "${system_mnt}" "${key_dir}/releasekey.x509.pem"
  reapply_file_security_context "${system_mnt}" "${root_fs_dir}"

  # Sanity check.
  snapshot_file_properties "${system_mnt}" > "${working_dir}/properties.new"
  local d
  if ! d=$(diff "${working_dir}"/properties.{orig,new}); then
    die "Unexpected change of file property, diff\n${d}"
  fi

  info "Repacking squashfs image"
  local old_size=$(stat -c '%s' "${system_img}")
  # Overwrite the original image.
  sudo "${mksquashfs}" "${system_mnt}" "${system_img}" \
      -no-progress -comp "${compression_method}" -noappend
  local new_size=$(stat -c '%s' "${system_img}")
  info "Android system image size change: ${old_size} -> ${new_size}"
}

main "$@"
