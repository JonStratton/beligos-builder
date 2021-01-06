#!/bin/sh

# If KVM is available, check so we can add it to our runners
kvm=''
if [ `cat /proc/cpuinfo | grep 'vmx\|svm' | wc -l` -ge 1 ]; then
   kvm='-cpu host -enable-kvm'
fi

# Arch for ISO and qemu
iso_arch='386'
qemu_arch='i386'
arch=`uname -m`
if [ $arch = 'x86_64' ]; then
   iso_arch='amd64'
   qemu_arch=$arch
fi
local_iso="iso/9front.$iso_arch.iso"

###########
# Keepass #
###########
# Create keepass db(belagos.kdbx) so we dont have to default passwords.
if [ ! -f belagos.kdbx ]; then
   create_grid/keepass.exp
fi

################
# Download ISO #
################

if [ $1 ]; then
   local_iso=$1
   echo "using $local_iso"
elif [ ! -f $local_iso ]; then
   # TODO, replace with torrent to avoid angering 9front
   mkdir iso
   remote_iso=`wget -O - http://9front.org/iso/ 2>/dev/null | grep ".$iso_arch.iso.gz<" | cut -d'"' -f4`
   wget -O $local_iso.gz http://9front.org/iso/$remote_iso
   gunzip $local_iso.gz
fi

###########
# FSSERVE #
###########
mkdir img
mkdir bin

echo "qemu-system-$qemu_arch $kvm -m 256 -net nic,macaddr=52:54:00:00:EE:03 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_fsserve.img -device scsi-hd,drive=vd0 \$*" > bin/run_fsserve.sh
chmod u+x bin/run_fsserve.sh

# This can be large, as all other VMs will boot off of this disk
#qemu-img create -f qcow2 img/9front_fsserve.img 10G

# Creating base install image
#create_grid/9front_install.exp bin/run_fsserve.sh $local_iso

# Back it up as expect is unrelyable with curses
cp img/9front_fsserve.img img/9front_fsserve.img_back

# Set up networking and turn on PXE
create_grid/9front_fsserve.exp bin/run_fsserve.sh

# bin/boot_headless.exp bin/run_fsserve.sh
# /opt/drawterm/drawterm -G -h 192.168.9.3 -a 192.168.9.3 -u glenda -c "/mnt/term/`pwd`/rc/fsserve_build.rc; fshalt"

#############
# AUTHSERVE #
#############
# fsserve needs to be done first, as authserve netboots from it

echo "qemu-system-$qemu_arch $kvm -m 256 -net nic,macaddr=52:54:00:00:EE:04 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_authserve.img -device scsi-hd,drive=vd0 -boot n \$*" > bin/run_authserve.sh
chmod u+x bin/run_authserve.sh

qemu-img create -f qcow2 img/9front_authserve.img 1M
#create_grid/9front_authserve.exp bin/run_authserve.sh

############
# CPUSERVE #
############

echo "qemu-system-$qemu_arch $kvm -smp 4 -m 256 -net nic,macaddr=52:54:00:00:EE:05 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_cpuserve.img -device scsi-hd,drive=vd0 -boot n \$*" > bin/run_cpuserve.sh
chmod u+x bin/run_cpuserve.sh

qemu-img create -f qcow2 img/9front_cpuserve.img 1M
#create_grid/9front_authserve.exp bin/run_cpuserve.sh
