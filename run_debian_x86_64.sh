#!/bin/bash

# Note: This file is referred to 
# https://github.com/runninglinuxkernel/runninglinuxkernel_5.0/blob/rlk_5.0/run_debian_x86_64.sh

LROOT=$PWD
JOBCOUNT=${JOBCOUNT=$(nproc)}
export ARCH=x86_64
export INSTALL_PATH=$LROOT/rootfs_debian_x86_64/boot/
export INSTALL_MOD_PATH=$LROOT/rootfs_debian_x86_64/
export INSTALL_HDR_PATH=$LROOT/rootfs_debian_x86_64/usr/

kernel_build=$PWD/rootfs_debian_x86_64/usr/src/linux/
rootfs_path=$PWD/rootfs_debian_x86_64
rootfs_image=$PWD/rootfs_debian_x86_64.ext4

rootfs_size=6144
lustre_rootfs_size=6144
cn_rootfs_size=6144
login_rootfs_size=6144

lustre_ost_size=10240
lustre_ost_name=$PWD/lustre_ost.img
lustre_mdt_size=5120
lustre_mdt_name=$PWD/lustre_mdt.img
lustre_mgs_size=2560
lustre_mgs_name=$PWD/lustre_mgs.img

SMP="-smp 16 -enable-kvm -cpu host"
CN_SMP="-smp 3 -enable-kvm -cpu host"
LUSTRE_SMP="-smp 2 -enable-kvm -cpu host"

if [ $# -lt 1 ]; then
	echo "Usage: $0 [arg]"
	echo "build_kernel: build the kernel image."
	echo "build_rootfs: build the rootfs image, need root privilege"
	echo "update_rootfs: update kernel modules for rootfs image, need root privilege."
	echo "run: run debian system."
	echo "run debug: enable gdb debug server."
fi

if [ $# -eq 2 ] && [ $2 == "debug" ]; then
	echo "Enable qemu debug server"
	DBG="-s -S"
	SMP=""
fi

make_kernel_image(){
		echo "start build kernel image..."
		make debian_defconfig
		make -j $JOBCOUNT
}

make_lustre_image(){
		echo "start build lustre ost image..."
		dd if=/dev/zero of=${lustre_ost_name}_1 bs=1M count=$lustre_ost_size
		dd if=/dev/zero of=${lustre_ost_name}_2 bs=1M count=$lustre_ost_size
		dd if=/dev/zero of=${lustre_ost_name}_3 bs=1M count=$lustre_ost_size
		dd if=/dev/zero of=${lustre_ost_name}_4 bs=1M count=$lustre_ost_size
		echo "start build lustre mdt image..."
		dd if=/dev/zero of=${lustre_mdt_name} bs=1M count=$lustre_mdt_size
		echo "start build lustre mgs image..."
		dd if=/dev/zero of=${lustre_mgs_name} bs=1M count=$lustre_mgs_size
}

prepare_rootfs(){
		if [ ! -d $rootfs_path ]; then
			echo "decompressing rootfs..."
			# split -d -b 60m rootfs_debian_x86_64.tar.xz -- rootfs_debian_x86_64.part 
			cat rootfs_debian_x86_64.part0* > rootfs_debian_x86_64.tar.xz
			tar -Jxf rootfs_debian_x86_64.tar.xz
		fi
}

build_kernel_devel(){
	kernver="$(make -s kernelrelease)"
	echo "kernel version: $kernver"

	mkdir -p $kernel_build
	rm rootfs_debian_x86_64/lib/modules/$kernver/build
	cp -a include $kernel_build
	cp Makefile .config Module.symvers System.map $kernel_build
	mkdir -p $kernel_build/arch/x86/
	mkdir -p $kernel_build/arch/x86/kernel/
	mkdir -p $kernel_build/scripts

	cp -a arch/x86/include $kernel_build/arch/x86/
	cp -a arch/x86/Makefile $kernel_build/arch/x86/
	cp -a scripts $kernel_build
	#cp arch/x86/kernel/module.lds $kernel_build/arch/x86/kernel/

	ln -s /usr/src/linux rootfs_debian_x86_64/lib/modules/$kernver/build

}

check_root(){
		if [ "$(id -u)" != "0" ];then
			echo "superuser privileges are required to run"
			echo "sudo ./run_debian_x86_64.sh build_rootfs"
			exit 1
		fi
}

update_rootfs(){
		if [ ! -f $rootfs_image ]; then
			echo "rootfs image is not present..., pls run build_rootfs"
		else
			echo "update rootfs ..."

			mkdir -p $rootfs_path
			echo "mount ext4 image into rootfs_debian_x86_64"
			mount -t ext4 $rootfs_image $rootfs_path -o loop

			make install
			make modules_install -j $JOBCOUNT
			make headers_install

			build_kernel_devel

			umount $rootfs_path
			chmod 777 $rootfs_image

			rm -rf $rootfs_path
		fi

}

build_rootfs(){
		if [ ! -f $rootfs_image ]; then
			make install
			make modules_install -j $JOBCOUNT
			make headers_install

			build_kernel_devel

			echo "making image..."
			dd if=/dev/zero of=$rootfs_image bs=1M count=$rootfs_size
			mkfs.ext4 $rootfs_image
			mkdir -p tmpfs
			echo "copy data into rootfs..."
			mount -t ext4 $rootfs_image tmpfs/ -o loop
			cp -af $rootfs_path/* tmpfs/
			umount tmpfs
			chmod 777 $rootfs_image

			rm -rf $rootfs_path
		fi
}

run_qemu_debian(){
		qemu-system-x86_64 -m 4096\
			-nographic $SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_debian_x86_64.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev user,id=mynet\
			-device virtio-net-pci,netdev=mynet\
			$DBG
			# --fsdev local,id=kmod_dev,path=./kmodules,security_model=none \
			# -device virtio-9p-pci,fsdev=kmod_dev,mount_tag=kmod_mount\
			# -net user,hostfwd=tcp::8888-:22 \
			# -net nic,model=virtio \
}

run_lustre_oss_1(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $LUSTRE_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_oss_1.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:09:62:cd:1c \
			-netdev user,id=mynet \
			-device virtio-net-pci,netdev=mynet\
			-drive if=none,file=${lustre_ost_name}_1,id=hd1 \
			-device virtio-blk-pci,drive=hd1 \
			# -netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			# -device virtio-net-pci,netdev=tapnet,mac=80:d4:09:62:cd:3c \
			$DBG
			# --fsdev local,id=kmod_dev,path=./kmodules,security_model=none \
			# -device virtio-9p-pci,fsdev=kmod_dev,mount_tag=kmod_mount\
			# -net user,hostfwd=tcp::8888-:22 \
			# -net nic,model=virtio \
}

run_lustre_oss_2(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $LUSTRE_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_oss_2.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:09:62:cd:2c \
			-drive if=none,file=${lustre_ost_name}_2,id=hd2 \
			-device virtio-blk-pci,drive=hd2 \
			$DBG
}

run_lustre_oss_3(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $LUSTRE_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_oss_3.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=82:d4:09:62:cd:3c \
			-drive if=none,file=${lustre_ost_name}_3,id=hd1 \
			-device virtio-blk-pci,drive=hd1 \
			-drive if=none,file=${lustre_ost_name}_4,id=hd2 \
			-device virtio-blk-pci,drive=hd2 \
			$DBG
}

run_lustre_mds(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $LUSTRE_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_mds.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:09:62:2d:4c \
			-drive if=none,file=${lustre_mgs_name},id=hd1 \
			-device virtio-blk-pci,drive=hd1 \
			-drive if=none,file=${lustre_mdt_name},id=hd2 \
			-device virtio-blk-pci,drive=hd2 \
			$DBG
}

run_cn_1(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $CN_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_cn_1.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev user,id=mynet\
			-device virtio-net-pci,netdev=mynet\
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:19:62:2d:5c \
			$DBG
}

run_cn_2(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $CN_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_cn_2.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev user,id=mynet\
			-device virtio-net-pci,netdev=mynet\
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:29:62:2d:6c \
			$DBG
}

run_cn_3(){
		sudo qemu-system-x86_64 -m 4096\
			-nographic $CN_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_cn_3.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev user,id=mynet\
			-device virtio-net-pci,netdev=mynet\
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:39:62:2d:7c \
			$DBG
}

run_master(){
		sudo qemu-system-x86_64 -m 8094\
			-nographic $CN_SMP -kernel arch/x86/boot/bzImage \
			-append "noinintrd console=ttyS0 crashkernel=256M root=/dev/vda rootfstype=ext4 rw loglevel=8 nokaslr" \
			-drive if=none,file=rootfs_master.ext4,id=hd0 \
			-device virtio-blk-pci,drive=hd0 \
			-netdev user,id=mynet\
			-device virtio-net-pci,netdev=mynet\
			-netdev tap,id=tapnet,script=$PWD/net_up,downscript=$PWD/net_down \
			-device virtio-net-pci,netdev=tapnet,mac=80:d4:39:62:2d:8c \
			$DBG
}

case $1 in
	build_kernel)
		make_kernel_image
		#prepare_rootfs
		#build_rootfs
		;;
	
	build_rootfs)
		#make_kernel_image
		check_root
		prepare_rootfs
		build_rootfs
		;;
	update_rootfs)
		check_root
		update_rootfs
		;;
	build_images)
		make_lustre_image
		;;
	run_lustre_oss)
		if [ ! -f $LROOT/arch/x86/boot/bzImage ]; then
			echo "canot find kernel image, pls run build_kernel command firstly!!"
			echo "./run_debian_x86_64.sh build_kernel"
			exit 1
		fi

		if [ ! -f $rootfs_image ]; then
			echo "canot find rootfs image, pls run build_rootfs command firstly!!"
			echo "sudo ./run_debian_x86_64.sh build_rootfs"
			exit 1
		fi

		run_lustre_oss_1
		;;
	run_lustre_oss_1)
		run_lustre_oss_1
		;;
	run_lustre_oss_2)
		run_lustre_oss_2
		;;
	run_lustre_oss_3)
		run_lustre_oss_3
		;;
	run_lustre_mds)
		if [ ! -f $LROOT/arch/x86/boot/bzImage ]; then
			echo "canot find kernel image, pls run build_kernel command firstly!!"
			echo "./run_debian_x86_64.sh build_kernel"
			exit 1
		fi

		if [ ! -f $rootfs_image ]; then
			echo "canot find rootfs image, pls run build_rootfs command firstly!!"
			echo "sudo ./run_debian_x86_64.sh build_rootfs"
			exit 1
		fi

		run_lustre_mds
		;;
	run_cn_1)
		run_cn_1
		;;
	run_cn_2)
		run_cn_2
		;;
	run_cn_3)
		run_cn_3
		;;
	run_master)
		run_master
		;;
	run)

		if [ ! -f $LROOT/arch/x86/boot/bzImage ]; then
			echo "canot find kernel image, pls run build_kernel command firstly!!"
			echo "./run_debian_x86_64.sh build_kernel"
			exit 1
		fi

		if [ ! -f $rootfs_image ]; then
			echo "canot find rootfs image, pls run build_rootfs command firstly!!"
			echo "sudo ./run_debian_x86_64.sh build_rootfs"
			exit 1
		fi

		#prepare_rootfs
		#build_rootfs
		run_qemu_debian
		;;
esac

