#!/bin/bash
#
# Copyright (C) 2012-2013 Red Hat, Inc. All rights reserved.
#
# This file is part of LVM2.
#
# This copyrighted material is made available to anyone wishing to use,
# modify, copy, or redistribute it subject to the terms and conditions
# of the GNU General Public License v.2.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# Author: Peter Rajnoha <prajnoha at redhat.com>
#
# Script for deactivating block devices
#
# Requires:
#   bash >= 4.0 (associative array support)
#   lsblk >= 2.22 (lsblk -s support)
#   umount
#   dmsetup >= 1.02.68 (--retry option support)
#   lvm >= 2.2.89 (activation/retry_deactivation config support)
#

#set -x
shopt -s dotglob nullglob

TOOL=blkdeactivate

DEV_DIR='/dev'
SYS_BLK_DIR='/sys/block'

UMOUNT="/bin/umount"
DMSETUP="${exec_prefix}/sbin/dmsetup"
LVM="${exec_prefix}/sbin/lvm"

if $UMOUNT --help | grep -- "--all-targets" >$DEV_DIR/null; then
	UMOUNT_OPTS="--all-targets "
else
	UMOUNT_OPTS=""
	FINDMNT="/bin/findmnt -r --noheadings -u -o TARGET"
	FINDMNT_READ="read -r mnt"
fi
DMSETUP_OPTS=""
LVM_OPTS=""

LSBLK="/bin/lsblk -r --noheadings -o TYPE,KNAME,NAME,MOUNTPOINT"
LSBLK_VARS="local devtype local kname local name local mnt"
LSBLK_READ="read -r devtype kname name mnt"
SORT_MNT="/bin/sort -r -u -k 4"

# Do not show tool errors by default (only done/skipping summary
# message provided by this script) and no verbose mode by default.
ERRORS=0
VERBOSE=0

# Do not unmount mounted devices by default.
DO_UMOUNT=0

# Deactivate each LV separately by default (not the whole VG).
LVM_DO_WHOLE_VG=0
# Do not retry LV deactivation by default.
LVM_CONFIG="activation{retry_deactivation=0}"

#
# List of device names and/or VGs to be skipped.
# Device name is the KNAME from lsblk output.
#
# If deactivation of any device fails, it's automatically
# added to the SKIP_DEVICE_LIST (also a particular VG
# added to the SKIP_VG_LIST for a device that is an LV).
#
# These lists provide device tree pruning to skip
# particular device/VG deactivation that failed already.
# (lists are associative arrays!)
#
declare -A SKIP_DEVICE_LIST=()
declare -A SKIP_VG_LIST=()

#
# List of mountpoints to be skipped. Any device that is mounted on the mountpoint
# listed here will be added to SKIP_DEVICE_LIST (and SKIP_VG_LIST) automatically.
# (list is an associative array!)
#
declare -A SKIP_UMOUNT_LIST=(["/"]=1 ["/boot"]=1 \
                             ["/lib"]=1 ["/lib64"]=1 \
                             ["/bin"]=1 ["/sbin"]=1 \
                             ["/var"]=1 ["/var/log"]=1 \
                             ["/usr"]=1 \
                             ["/usr/lib"]=1 ["/usr/lib64"]=1 \
                             ["/usr/sbin"]=1 ["/usr/bin"]=1)
# Bash can't properly handle '[' and ']' used as a subscript
# within the '()'initialization - it needs to be done separately!
SKIP_UMOUNT_LIST["[SWAP]"]=1

usage() {
	echo "${TOOL}: Utility to deactivate block devices"
	echo
	echo "  ${TOOL} [options] [device...]"
	echo "    - Deactivate block device tree."
	echo "      If devices are specified, deactivate only supplied devices and their holders."
	echo
	echo "  Options:"
	echo "    -e | --errors                Show errors reported from tools"
	echo "    -h | --help                  Show this help message"
	echo "    -d | --dmoption  DM_OPTIONS  Comma separated DM specific options"
	echo "    -l | --lvmoption LVM_OPTIONS Comma separated LVM specific options"
	echo "    -u | --umount                Unmount the device if mounted"
	echo "    -v | --verbose               Verbose mode (also implies -e)"
	echo
	echo "  Device specific options:"
	echo "    DM_OPTIONS:"
	echo "      retry    retry removal several times in case of failure"
	echo "      force    force device removal"
	echo "    LVM_OPTIONS:"
	echo "      retry    retry removal several times in case of failure"
	echo "      wholevg  deactivate the whole VG when processing an LV"

	exit
}

add_device_to_skip_list() {
	SKIP_DEVICE_LIST+=(["$kname"]=1)
	return 1
}

add_vg_to_skip_list() {
	SKIP_VG_LIST+=(["$DM_VG_NAME"]=1)
	return 1
}

is_top_level_device() {
	# top level devices do not have any holders, that is
	# the SYS_BLK_DIR/<device_name>/holders dir is empty
	files="`echo $SYS_BLK_DIR/$kname/holders/*`"
	test -z "$files"
}

device_umount_one() {
	test -z "$mnt" && return 0

	if test -z "${SKIP_UMOUNT_LIST["$mnt"]}" -a "$DO_UMOUNT" -eq "1"; then
		echo -n "  [UMOUNT]: unmounting $name ($kname) mounted on $mnt... "
		if eval $UMOUNT $UMOUNT_OPTS "$(printf $mnt)" $OUT $ERR; then
			echo "done"
		else
			echo "skipping"
			add_device_to_skip_list
		fi
	else
		echo "  [SKIP]: unmount of $name ($kname) mounted on $mnt"
		add_device_to_skip_list
	fi
}

device_umount() {
	test "$devtype" != "lvm" && test "${kname:0:3}" != "dm-" && return 0

	# FINDMNT is defined only if umount --all-targets is not available.
	# In that case, read the list of multiple mount points of one device
	# using FINDMNT and unmount it one by one manually.
	if test -z "$FINDMNT"; then
		device_umount_one
	else
		while $FINDMNT_READ; do
			device_umount_one || return 1
		done <<< "`$FINDMNT $DEV_DIR/$kname`"
	fi

}

deactivate_holders () {
	local skip=1; $LSBLK_VARS

	# Get holders for the device - either a mount or another device.
	# First line on the lsblk output is the device itself - skip it for
	# the deactivate call as this device is already being deactivated.
	while $LSBLK_READ; do
		test -e $SYS_BLK_DIR/$kname || continue
		# check if the device not on the skip list already
		test -z ${SKIP_DEVICE_LIST["$kname"]} || return 1

		# try to deactivate the holder
		test $skip -eq 1 && skip=0 && continue
		deactivate || return 1
	done <<< "`$LSBLK $1`"
}

deactivate_dm () {
	local name=$(printf $name)
	test -b "$DEV_DIR/mapper/$name" || return 0
	test -z ${SKIP_DEVICE_LIST["$kname"]} || return 1

	deactivate_holders "$DEV_DIR/mapper/$name" || return 1

	echo -n "  [DM]: deactivating $devtype device $name ($kname)... "
	if eval $DMSETUP $DMSETUP_OPTS remove "$name" $OUT $ERR; then
		echo "done"
	else
		echo "skipping"
		add_device_to_skip_list
	fi
}

deactivate_lvm () {
	local DM_VG_NAME; local DM_LV_NAME; local DM_LV_LAYER

	eval $(eval $DMSETUP splitname --nameprefixes --noheadings --rows "$name" LVM $ERR)
	test -b "$DEV_DIR/$DM_VG_NAME/$DM_LV_NAME" || return 0
	test -z ${SKIP_VG_LIST["$DM_VG_NAME"]} || return 1

	if test $LVM_DO_WHOLE_VG -eq 0; then
		# Deactivating only the LV specified
		deactivate_holders "$DEV_DIR/$DM_VG_NAME/$DM_LV_NAME" || {
			add_device_to_skip_list
			return 1
		}

		echo -n "  [LVM]: deactivating Logical Volume $DM_VG_NAME/$DM_LV_NAME... "
		if eval $LVM lvchange $LVM_OPTS --config \'log{prefix=\"\"} $LVM_CONFIG\' -aln $DM_VG_NAME/$DM_LV_NAME $OUT $ERR; then
			echo "done"
		else
			echo "skipping"
			add_device_to_skip_list
		fi

	else
		# Deactivating the whole VG the LV is part of
		lv_list=$(eval $LVM vgs --config "$LVM_CONFIG" --noheadings --rows -o lv_name $DM_VG_NAME $ERR)
		for lv in $lv_list; do
			test -b "$DEV_DIR/$DM_VG_NAME/$lv" || continue
			deactivate_holders "$DEV_DIR/$DM_VG_NAME/$lv" || {
				add_vg_to_skip_list
				return 1
			}
		done

		echo -n "  [LVM]: deactivating Volume Group $DM_VG_NAME... "
		if eval $LVM vgchange $LVM_OPTS --config \'log{prefix=\"    \"} $LVM_CONFIG\' -aln $DM_VG_NAME $OUT $ERR; then
			echo "done"
		else
			echo "skipping"
			add_vg_to_skip_list
		fi
	fi
}

deactivate () {
	######################################################################
	# DEACTIVATION HOOKS FOR NEW DEVICE TYPES GO HERE!                   #
	#                                                                    #
	# Identify a new device type either by inspecting the TYPE provided  #
	# by lsblk directly ($devtype) or by any other mean that is suitable #
	# e.g. the KNAME provided by lsblk ($kname). See $LSBLK_VARS for     #
	# complete list of variables that may be used. Then call a           #
	# device-specific deactivation function that handles the exact type. #
	#                                                                    #
        # This device-specific function will certainly need to call          #
	# deactivate_holders first to recursively deactivate any existing    #
	# holders it might have before deactivating the device it processes. #
	######################################################################
	if test "$devtype" = "lvm"; then
		deactivate_lvm
	elif test "${kname:0:3}" = "dm-"; then
		deactivate_dm
	fi
}

deactivate_all() {
	$LSBLK_VARS
	skip=0

	echo "Deactivating block devices:"

	if test $# -eq 0; then
		#######################
		# Process all devices #
		#######################

		# Unmount all relevant mountpoints first
		while $LSBLK_READ; do
			device_umount
		done <<< "`$LSBLK | $SORT_MNT`"

		# Do deactivate
		while $LSBLK_READ; do
			# 'disk' is at the bottom already and it's a real device
			test "$devtype" = "disk" && continue

			# if deactivation of any device fails, skip processing
			# any subsequent devices within its subtree as the
			# top-level device could not be deactivated anyway
			test $skip -eq 1 && {
				# reset 'skip' on top level device
				is_top_level_device && skip=0 || continue
			}

			# check if the device is not on the skip list already
			test -z ${SKIP_DEVICE_LIST["$kname"]} || continue

			# try to deactivate top-level device, set 'skip=1'
			# if it fails to do so - this will cause all the
			# device's subtree to be skipped when processing
			# devices further in this loop
			deactivate || skip=1
		done <<< "`$LSBLK -s`"
	else
		##################################
		# Process only specified devices #
		##################################

		while test $# -ne 0; do
			# Unmount all relevant mountpoints first
			while $LSBLK_READ; do
				device_umount
			done <<< "`$LSBLK $1 | $SORT_MNT`"

			# Do deactivate
			# Single dm device tree deactivation.
			if test -b "$1"; then
				$LSBLK_READ <<< "`$LSBLK --nodeps $1`"

				# check if the device is not on the skip list already
				test -z ${SKIP_DEVICE_LIST["$kname"]} || continue

				deactivate
			else
				echo "$1: device not found"
				return 1
			fi
			shift
		done;
	fi
}

get_dmopts() {
	ORIG_IFS=$IFS; IFS=','

	for opt in $1; do
		case $opt in
			"") ;;
			"retry") DMSETUP_OPTS+="--retry " ;;
			"force") DMSETUP_OPTS+="--force " ;;
			*) echo "$opt: unknown DM option"
		esac
	done

	IFS=$ORIG_IFS
}

get_lvmopts() {
	ORIG_IFS=$IFS; IFS=','

	for opt in $1; do
		case "$opt" in
			"") ;;
			"retry") LVM_CONFIG="activation{retry_deactivation=1}" ;;
			"wholevg") LVM_DO_WHOLE_VG=1 ;;
			*) echo "$opt: unknown LVM option"
		esac
	done

	IFS=$ORIG_IFS
}

set_env() {
	if test "$ERRORS" -eq "1"; then
		unset ERR
	else
		ERR="2>$DEV_DIR/null"
	fi

	if test "$VERBOSE" -eq "1"; then
		unset OUT
		UMOUNT_OPTS+="-v"
		DMSETUP_OPTS+="-vvvv"
		LVM_OPTS+="-vvvv"
	else
		OUT="1>$DEV_DIR/null"
	fi
}

while test $# -ne 0; do
	case "$1" in
		"") ;;
		"-e"|"--errors") ERRORS=1 ;;
		"-h"|"--help") usage ;;
		"-d"|"--dmoption ") get_dmopts "$2" ; shift ;;
		"-l"|"--lvmoption ") get_lvmopts "$2" ; shift ;;
		"-u"|"--umount") DO_UMOUNT=1 ;;
		"-v"|"--verbose") VERBOSE=1 ; ERRORS=1 ;;
		"-vv") VERBOSE=1 ; ERRORS=1 ; set -x ;;
		*) break ;;
	esac
	shift
done

set_env
deactivate_all "$@"
