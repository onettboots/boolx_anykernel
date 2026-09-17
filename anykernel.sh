### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=BoolxKernel for Xiaomi Trinket devices by @onettboots
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=ginkgo
device.name2=willow
device.name3=laurel_sprout
supported.versions=10.0-16.0
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# Unified package support
ak3_device="$(getprop ro.product.vendor.device 2>/dev/null | tr -d '\r \n')";
[ -z "$ak3_device" ] && ak3_device="$(getprop ro.product.device 2>/dev/null | tr -d '\r \n')";
[ -z "$ak3_device" ] && ak3_device="$(getprop ro.build.product 2>/dev/null | tr -d '\r \n')";
if [ -z "$ak3_device" ]; then
  ak3_device="$(file_getprop /default.prop ro.product.vendor.device 2>/dev/null | tr -d '\r \n')";
  [ -z "$ak3_device" ] && ak3_device="$(file_getprop /default.prop ro.product.device 2>/dev/null | tr -d '\r \n')";
  [ -z "$ak3_device" ] && ak3_device="$(file_getprop /system/build.prop ro.product.vendor.device 2>/dev/null | tr -d '\r \n')";
  [ -z "$ak3_device" ] && ak3_device="$(file_getprop /system/build.prop ro.product.device 2>/dev/null | tr -d '\r \n')";
  [ -z "$ak3_device" ] && ak3_device="$(file_getprop /vendor/build.prop ro.product.vendor.device 2>/dev/null | tr -d '\r \n')";
fi
ak3_device="$(echo "$ak3_device" | tr '[:upper:]' '[:lower:]')";

# Helper print helpers for readable installer logs
printed_blank=0
print_blank_once() {
  if [ "$printed_blank" -eq 0 ]; then
    ui_print ""
    printed_blank=1
  fi
}
log_rom()  { print_blank_once; ui_print "[ROM] $1"; }
log_feat() { print_blank_once; ui_print "[FK]  $1"; }
log_part() { print_blank_once; ui_print "[DTB] $1"; }
log_warn() { print_blank_once; ui_print "[!]   $1"; }

# Keep legacy aliases used throughout the script
feature_ok()   { log_feat "$1"; }
feature_info() { log_feat "$1"; }
feature_warn() { log_warn "$1"; }

# Helper: detect and optionally auto-enable BPF spoofing
check_bpf_spoofing() {
  # Read checks from config:
  # scope|pattern|action|mode|detect_message
  # scope: vendor | system | both | or an explicit path starting with '/'
  # action: warn | auto
  if [ -f "$AKHOME/bpf_spoof.conf" ]; then
    bpf_spoof_checks="$(cat "$AKHOME/bpf_spoof.conf")"
  else
    # No config -> skip detection
    return 0
  fi

  # Don't override if user already set uname_bpf_spoof
  if [ "$cache_mounted" -eq 1 ] && [ -f /cache/fk_feat ] && grep -q "uname_bpf_spoof" /cache/fk_feat 2>/dev/null; then
    log_feat "BPF spoof: already set in fk_feat, skipping detection"
    return 0
  fi

  # Make sure /system and /vendor are mounted before scoped checks
  if [ ! -f /system/build.prop ] && [ ! -f /system/system/build.prop ]; then
    if ! mount /system 2>/dev/null; then
      mount /dev/block/by-name/system /system 2>/dev/null
    fi
  fi
  if [ ! -f /vendor/build.prop ]; then
    if ! mount /vendor 2>/dev/null; then
      mount /dev/block/by-name/vendor /vendor 2>/dev/null
    fi
  fi

  # Evaluate all entries and choose the best match (most specific)
  # Best = longest pattern length, tie -> auto over warn, tie -> earliest line number in target file, tie -> first config order
  best_len=0
  best_line_num=99999999
  best_entry=""
  best_action=""
  best_mode=""
  best_message=""
  best_index=99999999

  cfg_index=0
  oldIFS="$IFS"
  newline="$(printf '\n.')"
  newline="${newline%.}"
  IFS="$newline"
  for entry in $bpf_spoof_checks; do
    cfg_index=$((cfg_index + 1))
    entry="$(echo "$entry" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$entry" ] && continue
    case "$entry" in \#*) continue ;; esac
    scope="$(echo "$entry" | cut -d'|' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    pattern_raw="$(echo "$entry" | cut -d'|' -f2 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    action="$(echo "$entry" | cut -d'|' -f3 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    mode="$(echo "$entry" | cut -d'|' -f4 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    message="$(echo "$entry" | cut -d'|' -f5- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [ -z "$scope" ] || [ -z "$pattern_raw" ] || [ -z "$action" ] || [ -z "$mode" ]; then
      log_warn "BPF spoof: malformed config entry, skipping: $entry"
      continue
    fi

    case "$pattern_raw" in
      re:*) pattern="${pattern_raw#re:}"; grep_opts="-E" ;;
      ire:*) pattern="${pattern_raw#ire:}"; grep_opts="-Ei" ;;
      if:*) pattern="${pattern_raw#if:}"; grep_opts="-Fi" ;;
      *) pattern="$pattern_raw"; grep_opts="-F" ;;
    esac

    scope_lc="$(echo "$scope" | tr '[:upper:]' '[:lower:]')"
    case "$scope_lc" in
      vendor) targets="/vendor/build.prop" ;;
      system) targets="/system/system/build.prop /system/build.prop /system_root/system/build.prop /system_root/build.prop" ;;
      both) targets="/vendor/build.prop /system/system/build.prop /system/build.prop /system_root/system/build.prop /system_root/build.prop" ;;
      /*) targets="$scope" ;;
      *) targets="$scope" ;;
    esac

    for file_check in $(printf '%s' "$targets" | tr ' ' '\n'); do
      if [ -f "$file_check" ]; then
        match_info=$(grep $grep_opts -n -- "$pattern" "$file_check" 2>/dev/null | head -n1)
        if [ -n "$match_info" ]; then
          match_line=$(echo "$match_info" | cut -d: -f1)
          plen=$(printf "%s" "$pattern" | wc -c)
          entry_prio=0
          [ "$action" = "auto" ] && entry_prio=1
          best_prio=0
          [ "$best_action" = "auto" ] && best_prio=1
          if [ "$plen" -gt "$best_len" ] || \
             { [ "$plen" -eq "$best_len" ] && [ "$entry_prio" -gt "$best_prio" ]; } || \
             { [ "$plen" -eq "$best_len" ] && [ "$entry_prio" -eq "$best_prio" ] && [ "$match_line" -lt "$best_line_num" ]; } || \
             { [ "$plen" -eq "$best_len" ] && [ "$entry_prio" -eq "$best_prio" ] && [ "$match_line" -eq "$best_line_num" ] && [ "$cfg_index" -lt "$best_index" ] 2>/dev/null; }; then
            best_len=$plen
            best_line_num=$match_line
            best_entry="$entry"
            best_action="$action"
            best_mode="$mode"
            best_message="$message"
            best_index=$cfg_index
          fi
        fi
      fi
    done
  done
  IFS="$oldIFS"

  if [ -n "$best_entry" ]; then
    log_feat "$best_message"
    if [ "$best_action" = "auto" ]; then
      log_feat "BPF spoof: auto-enabled (mode $best_mode)"
      patch_cmdline "uname_bpf_spoof" "uname_bpf_spoof=$best_mode"
    else
      log_warn "BPF spoof: manual enable recommended (mode $best_mode)"
    fi
  fi
}


# Device-specific tweaks
case "$ak3_device" in
  *ginkgo*|*willow*)
    # Parse feature flags from /cache/fk_feat if present
    cache_mounted=0;
    if mountpoint -q /cache 2>/dev/null; then
      cache_mounted=1;
    else
      if mount /cache 2>/dev/null; then
        cache_mounted=1;
      fi
    fi

    fk_feat_legacy_timestamp=0


    ;;
  *laurel_sprout*)
    # Laurel-specific conservative tweaks
    # Respect /cache/fk_feat if user explicitly sets or disables legacy_timestamp_source
    if [ "$cache_mounted" -eq 1 ] && [ -f /cache/fk_feat ]; then
      if grep -q "legacy_timestamp_source=" /cache/fk_feat 2>/dev/null; then
        val=$(grep -o 'legacy_timestamp_source=[0-9]*' /cache/fk_feat | head -n1 | cut -d= -f2)
        patch_cmdline "legacy_timestamp_source" "legacy_timestamp_source=$val"
        log_feat "Legacy timestamp source: mode $val"
      else
        patch_cmdline "legacy_timestamp_source" "legacy_timestamp_source=1"
        log_feat "Legacy timestamp source: enabled (device default)"
      fi
    else
      patch_cmdline "legacy_timestamp_source" "legacy_timestamp_source=1"
      log_feat "Legacy timestamp source: enabled (device default)"
    fi

    patch_cmdline "no_kernel_dimming" "no_kernel_dimming=1"
    log_feat "Kernel dimming: disabled (laurel_sprout)"
    timestamp_handled=1
    ;;
  *)
    # No device-specific tweaks
    ;;
esac

case "$ak3_device" in
  *laurel_sprout*)
    log_part "Selecting laurel_sprout DTB/DTBO";
    # Unified zips must include device-named artifacts
    if [ -f "$AKHOME/dtb-laurel_sprout" ] && [ -f "$AKHOME/dtbo-laurel_sprout.img" ]; then
      cp -f "$AKHOME/dtb-laurel_sprout" "$AKHOME/dtb";
      cp -f "$AKHOME/dtbo-laurel_sprout.img" "$AKHOME/dtbo.img";
    else
      abort "laurel_sprout device detected but DTB/DTBO not present in zip. Aborting...";
    fi;
  ;;
  *ginkgo*|*willow*)
    log_part "Selecting ginkgo/willow DTB/DTBO";
    if [ -f "$AKHOME/dtb-ginkgo" ] && [ -f "$AKHOME/dtbo-ginkgo.img" ]; then
      cp -f "$AKHOME/dtb-ginkgo" "$AKHOME/dtb";
      cp -f "$AKHOME/dtbo-ginkgo.img" "$AKHOME/dtbo.img";
    else
      abort "ginkgo/willow device detected but DTB/DTBO not present in zip. Aborting...";
    fi;
  ;;
  *)
    # Other devices: no selection
    ;;
esac;

# boot install
split_boot; # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

# Check if vendor isn't already mounted. This should make the detection work on flasher apps.
do_patch=1;
if [ ! -e /vendor/etc/fstab.qcom ]; then
	if [ -e /dev/block/by-name/vendor ]; then
		mount /dev/block/by-name/vendor /vendor
		if [ $? -ne 0 ]; then
			do_patch=0
		fi
	else
		# If the block device for vendor isn't present at that location, it might mean this a dynamic partitions ROM.
		mount /vendor
		if [ $? -ne 0 ]; then
			do_patch=0
		fi
	fi
fi

# Run BPF spoof detection after vendor is mounted (or confirmed unmountable)
check_bpf_spoofing

# Check for the presence of "first_stage_mount" in /vendor/etc/fstab only for /system or /vendor
if [ $do_patch -eq 1 ]; then
	if grep "first_stage_mount" /vendor/etc/fstab.qcom | grep -E -q '(/system|/vendor)'; then
		log_rom "Init mode: two-stage (patching cmdline)"
		patch_cmdline "tsinit" "tsinit"
	else
		log_rom "Init mode: legacy (no patch needed)"
	fi
else
	log_warn "Init mode: skipping cmdline patch, vendor not mounted"
fi

# Check if /cache is mounted, try to mount if not
cache_mounted=0;
if mountpoint -q /cache 2>/dev/null; then
  cache_mounted=1;
else
  if mount /cache 2>/dev/null; then
    cache_mounted=1;
  fi
fi

# Check for feature flags in /cache/fk_feat
fk_feat_legacy_timestamp=0
# fk_feat_uname_bpf_spoof=0

if [ "$cache_mounted" -eq 1 ] && [ -f /cache/fk_feat ]; then
  if grep -q "no_init_protection" /cache/fk_feat 2>/dev/null; then
    log_feat "Init protection: disabled"
    patch_cmdline "no_init_protection" "no_init_protection=1"
  fi

if grep -q "legacy_timestamp_source=" /cache/fk_feat 2>/dev/null; then
        val=$(grep -o 'legacy_timestamp_source=[0-9]*' /cache/fk_feat | head -n1 | cut -d= -f2)
        log_feat "Legacy timestamp source: mode $val"
        patch_cmdline "legacy_timestamp_source" "legacy_timestamp_source=$val"
    fk_feat_legacy_timestamp=1
  fi

  if grep -q "uname_bpf_spoof=" /cache/fk_feat 2>/dev/null; then
    val=$(grep -o 'uname_bpf_spoof=[0-9]*' /cache/fk_feat | head -n1 | cut -d= -f2)
    log_feat "BPF spoof: mode $val"
    patch_cmdline "uname_bpf_spoof" "uname_bpf_spoof=$val"
    # fk_feat_uname_bpf_spoof=1
  elif grep -q "uname_bpf_spoof" /cache/fk_feat 2>/dev/null; then
    log_feat "BPF spoof: mode 2"
    patch_cmdline "uname_bpf_spoof" "uname_bpf_spoof=2"
    # fk_feat_uname_bpf_spoof=1
  fi

  if grep -q "no_msm_perf_boost" /cache/fk_feat 2>/dev/null; then
    log_feat "MSM performance boost: disabled"
    patch_cmdline "no_msm_perf_boost" "no_msm_perf_boost=1"
  fi

  if grep -q "warm_reboot" /cache/fk_feat 2>/dev/null; then
    log_feat "Warm reboot: forced"
    patch_cmdline "warm_reboot" "warm_reboot=1"
  fi
fi

# # Enable bpf spoofing (only if not already set via fk_feat)
# if [ "$fk_feat_uname_bpf_spoof" -eq 0 ]; then
#   patch_uname_bpf_spoof() {
#     patch_cmdline "uname_bpf_spoof" "uname_bpf_spoof=1"
#   }

#   # if device is running HyperMINT ROM
#   if [ -f /vendor/build.prop ]; then
#     if grep -q -E 'MINT|mintdevice' /vendor/build.prop; then
#       ui_print "HyperMINT ROM detected, enabling bpf spoof..."
#       patch_uname_bpf_spoof
#     fi
#   fi
# fi

# Check for IR HAL type
if [ -f /vendor/bin/hw/android.hardware.ir-service.lineage ]; then
	log_feat "IR HAL: LIRC-based"
else
	log_feat "IR HAL: legacy spidev"
	patch_cmdline "legacy_ir_hal" "legacy_ir_hal=1"
fi

# Get Android version from build.prop and set legacy_timestamp_source (only if not already set via fk_feat)
# Skip if a device-specific handler already performed this
if [ "${timestamp_handled:-0}" -eq 0 ] && [ "$fk_feat_legacy_timestamp" -eq 0 ]; then
  android_ver=$(file_getprop /system/build.prop ro.build.version.release)

  # Convert to integer (strip potential decimal points)
  android_ver=${android_ver%%.*}

  # Check if Android version is 11 or lower
  if [ "$android_ver" -le 11 ] 2>/dev/null; then
    patch_cmdline "legacy_timestamp_source" "legacy_timestamp_source=1"
    log_feat "Legacy timestamp source: enabled"
  else
    patch_cmdline "legacy_timestamp_source" "legacy_timestamp_source=0"
    log_feat "Legacy timestamp source: not needed"
  fi
fi

flash_boot; # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
flash_dtbo;
## end boot install


## init_boot files attributes
#init_boot_attributes() {
#set_perm_recursive 0 0 755 644 $RAMDISK/*;
#set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
#} # end attributes

# init_boot shell variables
#BLOCK=init_boot;
#IS_SLOT_DEVICE=1;
#RAMDISK_COMPRESSION=auto;
#PATCH_VBMETA_FLAG=auto;

# reset for init_boot patching
#reset_ak;

# init_boot install
#dump_boot; # unpack ramdisk since it is the new first stage init ramdisk where overlay.d must go

#write_boot;
## end init_boot install


## vendor_kernel_boot shell variables
#BLOCK=vendor_kernel_boot;
#IS_SLOT_DEVICE=1;
#RAMDISK_COMPRESSION=auto;
#PATCH_VBMETA_FLAG=auto;

# reset for vendor_kernel_boot patching
#reset_ak;

# vendor_kernel_boot install
#split_boot; # skip unpack/repack ramdisk, e.g. for dtb on devices with hdr v4 and vendor_kernel_boot

#flash_boot;
## end vendor_kernel_boot install


## vendor_boot files attributes
#vendor_boot_attributes() {
#set_perm_recursive 0 0 755 644 $RAMDISK/*;
#set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
#} # end attributes

# vendor_boot shell variables
#BLOCK=vendor_boot;
#IS_SLOT_DEVICE=1;
#RAMDISK_COMPRESSION=auto;
#PATCH_VBMETA_FLAG=auto;

# reset for vendor_boot patching
#reset_ak;

# vendor_boot install
#dump_boot; # use split_boot to skip ramdisk unpack, e.g. for dtb on devices with hdr v4 but no vendor_kernel_boot

#write_boot; # use flash_boot to skip ramdisk repack, e.g. for dtb on devices with hdr v4 but no vendor_kernel_boot
## end vendor_boot install
