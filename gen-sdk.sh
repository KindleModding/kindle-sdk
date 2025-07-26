#!/bin/bash

set -e # Stop on error

# 7zip CLI may be installed as "7z" or "7zz" depending on the distribution
sevenzip=7z
if ! command -v $sevenzip >/dev/null 2>&1; then
    sevenzip=7zz
    if ! command -v $sevenzip >/dev/null 2>&1; then
        echo "[ERROR] 7z (or 7zz) not found! Please install 7zip to continue."
        exit 1
    fi
fi

RM_If_Exists() {
    if [ -d $1 ] || [ -f $1 ]; then
        rm -rf $1
    fi
}

Setup_SDK() {
    tc_target="$1"
    sdk_target="$2"
    FIRM_URLS=("${@:3}")
    if [[ -z $tc_dir ]]; then
        tc_dir="$HOME/x-tools/$tc_target"
    fi
    sysroot_dir="$tc_dir/$tc_target/sysroot"

    # If a previous version of this script left a mount around, clean it up
    sudo umount ./cache/${tc_target}/firmware*/mnt || true
    rm -rf ./cache/${tc_target}/firmware*/mnt
    
    case $sdk_target in
        kindlehf)
            arch="armhf"
            ;;
        *)
            arch="armel"
            ;;
    esac

    if ! [ -d $tc_dir ]; then
        echo "[ERROR] Toolchain not installed - Please setup koxtoolchain for target $tc_target"
        exit 1
    fi

    chmod -f a-w $tc_dir
    echo "[*] Setting up SDK for $1"

    echo "[*] Generating Meson crosscompilation file"
    chmod -f a+w $tc_dir

    if [ -f "$tc_dir/meson-crosscompile.txt" ]; then
        chmod -f a+w $tc_dir/meson-crosscompile.txt
    fi

    echo "[binaries]" > $tc_dir/meson-crosscompile.txt
    echo "c = '$tc_dir/bin/$tc_target-gcc'" >> $tc_dir/meson-crosscompile.txt
    echo "cpp = '$tc_dir/bin/$tc_target-g++'" >> $tc_dir/meson-crosscompile.txt
    echo "ar = '$tc_dir/bin/$tc_target-ar'" >> $tc_dir/meson-crosscompile.txt
    echo "strip = '$tc_dir/bin/$tc_target-strip'" >> $tc_dir/meson-crosscompile.txt
    echo "pkg-config = 'pkg-config'" >> $tc_dir/meson-crosscompile.txt
    echo "pkgconfig = 'pkg-config'" >> $tc_dir/meson-crosscompile.txt # Yeah ok don't give me that look
    echo "" >> $tc_dir/meson-crosscompile.txt
    echo "[built-in options]" >> $tc_dir/meson-crosscompile.txt
    echo "" >> $tc_dir/meson-crosscompile.txt
    echo "[host_machine]" >> $tc_dir/meson-crosscompile.txt
    echo "system = 'linux'" >> $tc_dir/meson-crosscompile.txt
    echo "cpu_family = 'arm'" >> $tc_dir/meson-crosscompile.txt
    echo "cpu = 'arm'" >> $tc_dir/meson-crosscompile.txt
    echo "endian = 'little'" >> $tc_dir/meson-crosscompile.txt
    echo "" >> $tc_dir/meson-crosscompile.txt
    echo "[properties]" >> $tc_dir/meson-crosscompile.txt
    echo "sys_root = '$tc_dir/$tc_target/sysroot'" >> $tc_dir/meson-crosscompile.txt
    echo "pkg_config_libdir = '$tc_dir/$tc_target/sysroot/usr/lib/pkgconfig'" >> $tc_dir/meson-crosscompile.txt
    echo "target='Kindle'" >> $tc_dir/meson-crosscompile.txt
    echo "arch = '$arch'" >> $tc_dir/meson-crosscompile.txt
    chmod -f a-w $tc_dir/meson-crosscompile.txt

    echo "[*] Building Latest KindleTool"
    cd KindleTool/
        make
    cd ..

    echo "[*] Downloading Kindle firmware"

    if ! [ -d "./cache/${tc_target}" ]; then
        mkdir -p ./cache/${tc_target}
    fi

    for i in "${!FIRM_URLS[@]}"; do
      if ! [ -f "./cache/${tc_target}/firmware_${i}.bin" ]; then
        echo "Downloading from: ${FIRM_URLS[i]}"
        if command -v aria2c >/dev/null 2>&1
        then
            aria2c -s 16 -x 16 -k 2M "${FIRM_URLS[i]}" -o "./cache/${tc_target}/firmware_${i}.bin"
        else
            curl --progress-bar -L -C - -o "./cache/${tc_target}/firmware_${i}.bin" "${FIRM_URLS[i]}"
        fi

        echo "[*] Extracting firmware #$((i+1))"
        if [ -d "./cache/${tc_target}/firmware_${i}/" ]; then
            rm -rf "./cache/${tc_target}/firmware_${i}/"
        fi
      else
        echo "Found firmware in cache - SKIPPING DOWNLOAD!"
      fi

      KindleTool/KindleTool/Release/kindletool extract "./cache/${tc_target}/firmware_${i}.bin" "./cache/${tc_target}/firmware_${i}/"
      cd "./cache/${tc_target}/firmware_${i}/"
          if [ -f rootfs.img ]; then
            rm rootfs.img
          fi

          gunzip rootfs.img.gz
          mkdir -p mnt
          # extract, "dangerously" write symlinks as links, output to mnt
          $sevenzip x -snld -omnt rootfs.img
      cd ../../..
    done

    echo "[*] Wiping target pkgconfig files"
    if [ -d "$sysroot_dir/usr/lib/pkgconfig" ]; then
        chmod -f a+w $sysroot_dir/usr/lib/
        chmod -f -R a+w $sysroot_dir/usr/lib/pkgconfig
        RM_If_Exists $sysroot_dir/usr/lib/pkgconfig
        chmod -f a-w $sysroot_dir/usr/lib/
    fi

    echo "[*] Parsing pkgconfig files for any"
    RM_If_Exists ./patch/any/usr/lib/pkgconfig
    mkdir -p ./patch/any/usr/lib/pkgconfig/
    cp -r ./pkgconfig/any/* ./patch/any/usr/lib/pkgconfig/
    for filepath in ./patch/any/usr/lib/pkgconfig/*
    do
        sed -i "s@%TARGET%@$tc_target@g" "$filepath"
    done

    if [ -d "./pkgconfig/$sdk_target" ]; then
        echo "[*] Parsing pkgconfig files for $sdk_target"
        RM_If_Exists ./patch/$sdk_target/usr/lib/pkgconfig
        mkdir -p ./patch/$sdk_target/usr/lib/pkgconfig/
        cp -r ./pkgconfig/$sdk_target/* ./patch/$sdk_target/usr/lib/pkgconfig/
        for filepath in ./patch/$sdk_target/usr/lib/pkgconfig/*
        do
            sed -i "s@%TARGET%@$tc_target@g" "$filepath"
        done
    fi

    echo "[*] Executing jobs for additional libraries"
    ###
    # Lipc
    ###
    echo "[*] Copying openlipc"
    cp ./modules/openlipc/include/openlipc.h ./patch/any/usr/include/lipc.h

    echo "[*] Copying cJSON"
    cp ./modules/cJSON/cJSON.h ./patch/any/usr/include/cJSON.h
    cp ./modules/cJSON/cJSON_Utils.h ./patch/any/usr/include/cJSON_Utils.h

    echo "[*] Copying libcurl"
    RM_If_Exists ./patch/any/usr/include/curl
    cp -r ./modules/curl/include/curl ./patch/any/usr/include/curl

    echo "[*] Copying patch files for any to sysroot"
    # Copy universal stuff
    cd "./patch/any"
        find . -type d -exec chmod -f -R a+w $sysroot_dir/{} ';'
    cd ../..

    chmod -f a+w $sysroot_dir/
    cp -r ./patch/any/* $sysroot_dir/
    chmod -f a-w $sysroot_dir/
    cd "./patch/any"
        find . -type d -exec chmod -f -R a-w $sysroot_dir/{} ';'
    cd ../..

    if [ -d "./patch/$sdk_target" ]; then
        echo "[*] Copying patch files for $sdk_target to sysroot"
        cd "./patch/$sdk_target"
            find . -type d -exec chmod -f -R a+w $sysroot_dir/{} ';'
        cd ../..

        chmod -f a+w $sysroot_dir/
        cp -r ./patch/$sdk_target/* $sysroot_dir/
        chmod -f a-w $sysroot_dir/
        cd "./patch/$sdk_target"
            find . -type d -exec chmod -f -R a-w $sysroot_dir/{} ';'
        cd ../..
    fi


    echo "[*] Copying firmware library files to sysroot"
    chmod -f -R a+w $sysroot_dir/lib
    chmod -f -R a+w $sysroot_dir/usr/lib

    # We overlay by copying and skipping files that already exist (-n isn't portable GOOGOO GAGA IT'S MORE PORTABLE THAN BLOODY OVERLAY MOUNTS (sorry im supposed to be writing DRM today not dealing with Kindle stuff))
    # OVERLAY MOUNTS CAN BITE ME!
    for i in "${!FIRM_URLS[@]}"; do
        echo "  - Copying firmware ${i}"
        set +e
        cp -rn --remove-destination ./cache/${tc_target}/firmware_${i}/mnt/usr/lib/* $sysroot_dir/usr/lib/
        cp -rn --remove-destination ./cache/${tc_target}/firmware_${i}/mnt/lib/* $sysroot_dir/lib/
        set -e
    done
    echo "[*] Patching symlinks"
    set +e # Temporarially disable error checking because some of these will fail bc they're referencing nonexistent targets
    find $sysroot_dir/usr/lib -type l -ls | grep "\-> /" | grep -v "\-> $sysroot_dir" | awk -v sysroot_dir="$sysroot_dir" '{print "rm " $11 "; ln -sf " sysroot_dir $13 " " $11}' | sh
    find $sysroot_dir/lib -type l -ls | grep "\-> /" | grep -v "\-> $sysroot_dir" | awk -v sysroot_dir="$sysroot_dir" '{print "rm " $11 "; ln -sf " sysroot_dir $13 " " $11}' | sh
    set -e
    chmod -f -R a-w $sysroot_dir/usr/lib
    chmod -f -R a-w $sysroot_dir/lib


    chmod -f a-w $tc_dir/


    echo "[*] Cleaning up"
    rm -rf ./cache/${tc_target}/firmware*/mnt

    echo "===================================================================================================="
    echo "[*] Kindle (unofficial) SDK Installed"
    echo "[*] To cross-compile via Meson, use the meson-crosscompile.txt file at:"
    echo "[*] $tc_dir/meson-crosscompile.txt"
    echo "===================================================================================================="
}

echo "========================="
echo "= Kindle SDK Installer  ="
echo "= Created by HackerDude ="
echo "================ v2.0.0 ="
echo
echo

cd $(dirname "$0")

HELP_MSG="
kindle-sdk - The Unofficial Kindle SDK

usage: $0 <platform> [path]

Supported platforms:

	kindlepw2
	kindlehf

If used, [path] should point to your installed toolchain, ie: '~/x-tools/arm-kindlehf-linux-gnueabihf'
"

if [ $# -lt 1 ]; then
	echo "Missing argument"
	echo "${HELP_MSG}"
	exit 1
fi

if [ $# -gt 1 ]; then
    tc_dir=$2
fi

case $1 in
	-h)
		echo "${HELP_MSG}"
		exit 0
		;;
	kindlehf)
		Setup_SDK "arm-kindlehf-linux-gnueabihf" "kindlehf" "https://s3.amazonaws.com/firmwaredownloads/update_kindle_all_new_paperwhite_v2_5.16.3.bin" "https://s3.amazonaws.com/firmwaredownloads/update_kindle_scribe_5.16.3.bin"
		;;
    kindlepw4)
        Setup_SDK "arm-kindlepw4-linux-gnueabi" "kindlepw2" "https://s3.amazonaws.com/firmwaredownloads/update_kindle_all_new_paperwhite_v2_5.10.1.2.bin"
		Setup_SDK "arm-kindlepw4-linux-gnueabi" "kindlepw4" "https://s3.amazonaws.com/firmwaredownloads/update_kindle_all_new_paperwhite_v2_5.10.1.2.bin"
		;;
	kindlepw2)
		Setup_SDK "arm-kindlepw2-linux-gnueabi" "kindlepw2" "https://s3.amazonaws.com/G7G_FirmwareUpdates_WebDownloads/update_kindle_5.4.2.bin"
		;;
	*)
		echo "[!] $1 not supported!"
		echo "${HELP_MSG}"
		exit 1
		;;
esac
