#!/bin/sh

# Arch for ISO and qemu
iso_arch='386'
qemu_arch='i386'
arch=`uname -m`
if [ $arch = 'x86_64' ]; then
   iso_arch='amd64'
   qemu_arch=$arch
fi
local_iso="9front.$iso_arch.iso"

# grid, solo/cpu, auth, fs
type='grid'
if [ $1 ]; then
   type=$1
fi

[ ! -d img ] && mkdir img
[ ! -d bin ] && mkdir bin

# Toggle on will prompt for passwords on boot
secure_boot=$2

#######################
# Disk and RAM Sizing #
#######################

# 512 for base debian gui, 64 for each plan9vm. Split the rest between the fsserve and the cpuserve(most)
total_core=`cat /proc/meminfo | grep "^MemTotal:" | awk '{print $2}'`
core_free_mb=`expr \( $total_core / 1024 \) - 512 - \( 64 \* 3 \)`
fsserve_core_default=`expr \( \( $core_free_mb \* 25 \) / 100 \) + 64`
cpuserve_core_default=`expr \( \( $core_free_mb \* 75 \) / 100 \) + 64`
authserve_core_default=64

# Overwrite defaults if above 2gb for 32 bit VMs.
[ $arch = 'i686' ] && [ $fsserve_core_default -gt 2000 ] && fsserve_core_default=2000
[ $arch = 'i686' ] && [ $cpuserve_core_default -gt 2000 ] && cpuserve_core_default=2000

# 75% of the free disk for fsserve
free_disk=`df -k 2>/dev/null | grep '/home/$' | awk '{print $4}'`
if [ ! $free_disk ]; then
   free_disk=`df -k 2>/dev/null | grep ' /$' | awk '{print $4}'`
fi
free_mb=`expr $free_disk / 1024`
fsserve_disk_gb_default=`expr \( \( $free_mb \* 75 \) / 100 \) / 1024`G
# Warn on RAM and Disk.
[ $free_mb -lt 10240 ] && echo "Warning, you seem to have less than 10G free. Installer may not work(???)."

# Prompt for values
if [ $type = 'grid' ]; then
   [ $core_free_mb -lt 704 ] && echo "Warning, you seem to have less RAM than can run your base OS plus 3 VMs"

   read -p "RAM in MB for fsserve(default $fsserve_core_default): " fsserve_core
   [ -z $fsserve_core ] && fsserve_core=$fsserve_core_default
   read -p "RAM in MB for cpuserve(default $cpuserve_core_default): " cpuserve_core
   [ -z $cpuserve_core ] && cpuserve_core=$cpuserve_core_default
   read -p "RAM in MB for authserve(default $authserve_core_default): " authserve_core
   [ -z $authserve_core ] && authserve_core=$authserve_core_default
   read -p "Disk for fsserve(default $fsserve_disk_gb_default): " fsserve_disk_gb
   [ -z $fsserve_disk_gb ] && fsserve_disk_gb=$fsserve_disk_gb_default
else
   read -p "RAM in MB for install(default $cpuserve_core_default): " cpuserve_core
   [ -z $cpuserve_core ] && cpuserve_core=$cpuserve_core_default
   read -p "Disk for install(default $fsserve_disk_gb_default): " fsserve_disk_gb
   [ -z $fsserve_disk_gb ] && fsserve_disk_gb=$fsserve_disk_gb_default
fi

############
# Password #
############
   # Use Glenda's password for the install

# Disk encryption
if [ $secure_boot ]; then
   if [ ! $DISK_PASS ]; then
      default=""
      read -p "Enter optional disk encryption password. If entered, this password will be required to boot: " DISK_PASS
      [ -z $DISK_PASS ] && DISK_PASS=$default
      export DISK_PASS
   fi
fi

if [ ! $GLENDA_PASS ]; then
   default=`< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c10`
   read -p "Enter password for glenda(default $default): " GLENDA_PASS
   [ -z $GLENDA_PASS ] && GLENDA_PASS=$default
   export GLENDA_PASS
fi

if [ ! $USER_PASS ]; then
   default=""
   read -p "Enter password for $USER to create user: " USER_PASS
   [ -z $USER_PASS ] && USER_PASS=$default
   export USER_PASS
fi

################
# Download ISO #
################
   # TODO, replace with torrent to avoid angering 9front

if [ ! -f $local_iso ]; then
   remote_iso=`wget -O - http://9front.org/iso/ 2>/dev/null | grep ".$iso_arch.iso.gz<" | cut -d'"' -f4`
   wget -O $local_iso.gz http://9front.org/iso/$remote_iso
   gunzip $local_iso.gz
fi

################
# Base Install #
################
   # This will be converted to our fsserve

mk_run_sh()
{
echo "#!/bin/sh
kvm=''
if [ \`cat /proc/cpuinfo | grep 'vmx\|svm' | wc -l\` -ge 1 ]; then
   kvm='-cpu host -enable-kvm'
fi" > $1
chmod a+x $1
}

mk_run_sh "bin/base_run.sh"
echo "#!/bin/sh\nqemu-system-$qemu_arch \$kvm -m $cpuserve_core -net nic,macaddr=52:54:00:00:EE:03 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_base.img -device scsi-hd,drive=vd0 -nographic \$*" >> bin/base_run.sh

# Run base installer directly
if [ ! -f img/9front_base.img ]; then
   # Pull the kern and init out, so we can boot in console mode
   7z e $local_iso cfg/plan9.ini -aoa
   7z e $local_iso $iso_arch/9pc* -aoa

   chmod 644 ./plan9.ini
   echo "console=0\n*acpi=1" >> ./plan9.ini

   qemu-img create -f qcow2 img/9front_base.img $fsserve_disk_gb
   build_grid/9front_base.exp bin/base_run.sh $local_iso

   rm ./plan9.ini
   rm ./9pc*
fi

#############
# SOLOSERVE #
#############

if [ $type != 'grid' ]; then
   mkfifo -m 622 img/solo_run_in
   mkfifo -m 644 img/solo_run_out
   mk_run_sh "bin/solo_run.sh"
   echo "qemu-system-$qemu_arch \$kvm -smp 2 -m $cpuserve_core -net nic,macaddr=52:54:00:00:EE:03 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_solo.img -device scsi-hd,drive=vd0 -nographic \$*" >> bin/solo_run.sh

   if [ ! -f img/9front_solo.img ]; then
      cp img/9front_base.img img/9front_solo.img

      # All Solo servers are CPU servers.
      build_grid/9front_base_cpuserve.exp bin/solo_run.sh
   fi
fi

###########
# FSSERVE #
###########

if [ $type = 'grid' ]; then
   mkfifo -m 622 img/fsserve_run_in
   mkfifo -m 644 img/fsserve_run_out
   mk_run_sh "bin/fsserve_run.sh"
   echo "qemu-system-$qemu_arch \$kvm -m $fsserve_core -net nic,macaddr=52:54:00:00:EE:03 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_fsserve.img -device scsi-hd,drive=vd0 -nographic \$*" >> bin/fsserve_run.sh

   if [ ! -f img/9front_fsserve.img ]; then
      cp img/9front_base.img img/9front_fsserve.img

      # Set up networking and turn on PXE
      build_grid/9front_base_cpuserve.exp bin/fsserve_run.sh
      build_grid/9front_fsserve_fscache.exp bin/fsserve_run.sh
      build_grid/9front_grid_pxe_server.exp bin/fsserve_run.sh
   fi

   bin/boot_wait.sh bin/fsserve_run.sh
fi

#############
# AUTHSERVE #
#############

if [ $type = 'grid' ]; then
   mkfifo -m 622 img/authserve_run_in
   mkfifo -m 644 img/authserve_run_out
   mk_run_sh "bin/authserve_run.sh"
   if [ ! $secure_boot ]; then
      echo "qemu-system-$qemu_arch \$kvm -m $authserve_core -net nic,macaddr=52:54:00:00:EE:04 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_authserve.img -device scsi-hd,drive=vd0 -boot n -nographic \$*" >> bin/authserve_run.sh
   else
      echo "qemu-system-$qemu_arch \$kvm -m $authserve_core -net nic,macaddr=52:54:00:00:EE:04 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -boot n -nographic \$*" >> bin/authserve_run.sh
   fi

   if [ ! -f img/9front_authserve.img ]; then
      if [ ! $secure_boot ]; then
         qemu-img create -f qcow2 img/9front_authserve.img 1M
         build_grid/9front_grid_pxe_client_nvram.exp bin/authserve_run.sh
      fi
      build_grid/9front_authserver_changeuser.exp bin/authserve_run.sh
   fi

   bin/boot_wait.sh bin/authserve_run.sh
fi

############
# CPUSERVE #
############

if [ $type = 'grid' ]; then
   mkfifo -m 622 img/cpuserve_run_in
   mkfifo -m 644 img/cpuserve_run_out
   mk_run_sh "bin/cpuserve_run.sh"
   if [ ! $secure_boot ]; then
      echo "qemu-system-$qemu_arch \$kvm -smp 4 -m $cpuserve_core -net nic,macaddr=52:54:00:00:EE:05 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -drive if=none,id=vd0,file=img/9front_cpuserve.img -device scsi-hd,drive=vd0 -boot n -nographic \$*" >> bin/cpuserve_run.sh
      if [ ! -f img/9front_cpuserve.img ]; then
         qemu-img create -f qcow2 img/9front_cpuserve.img 1M
         build_grid/9front_grid_pxe_client_nvram.exp bin/cpuserve_run.sh
      fi
   else
      echo "qemu-system-$qemu_arch \$kvm -smp 4 -m $cpuserve_core -net nic,macaddr=52:54:00:00:EE:05 -net vde,sock=/var/run/vde2/tap0.ctl -device virtio-scsi-pci,id=scsi -boot n -nographic \$*" >> bin/cpuserve_run.sh
   fi
fi

########################
# Turn down everything #
########################

if [ $type = 'grid' ]; then
   bin/belagos_client.sh authserve_run halt
   sleep 1
   bin/belagos_client.sh fsserve_run halt
fi
