#! /bin/bash
#
#	leveraged from mapr_imager.sh
#
# Script to be executed on top of a newly created Linux instance 
# to install MapR components for an instance image to be used later.
# The specific packages can be passed in via meta data (see maprpackages
# below)
#
# The resulting image will be used as a basis for configure-mapr-instance.sh
# See that script for the steps that need to be done BEFORE this node
# can successfully run MapR services.
#
# Expectations:
#	- Script run as root user (hence no need for permission checks)
#	- Basic distro differences (APT-GET vs YUM, etc) can be handled
#	    There are so few differences, it seemed better to manage one script.
#
# Tested with MapR 2.0.x and 2.1.x
#
# JAVA
#	This script default to OpenJDK; the logic to support Oracle JDK 
#   is included for users who which to implicitly accept Oracle's 
#	end-user license agreement.
#

# This instance may have been just started.
# Allow ample time for the network and setup processes to settle.
sleep 10

# Metadata for this installation ... pull out details that we'll need
# Google Compue Engine allows the create-instance operation to pass
# in parameters via this mechanism.
#	TBD : optionally allow MapR user and password to be passed in 
# 
murl_top=http://metadata/0.1/meta-data
murl_attr="${murl_top}/attributes"

THIS_FQDN=$(curl $murl_top/hostname)
THIS_HOST=${THIS_FQDN/.*/}
THIS_IMAGE=$(curl $murl_attr/image)    # name of initial image loaded here
MAPR_VERSION=$(curl $murl_attr/maprversion)    # mapr version, eg. 1.2.3

# A comma separated list of packages (without the "mapr-" prefix)
# to be installed.   This script assumes that NONE of them have 
# been installed.
MAPR_PACKAGES=$(curl -f $murl_attr/maprpackages)
MAPR_PACKAGES=${MAPR_PACKAGES:-"core,fileserver"}

# NOTE: We could be smart and look to see if THIS_IMAGE was a 
# MapR image, and bail on all the rest of this script.

# Definitions for our installation
#	These could just as easily be meta-data if we wanted to do extra work
MAPR_HOME=/opt/mapr
MAPR_USER=mapr
MAPR_PASSWD=MapR


LOG=/tmp/prepare-mapr-image.log
OUT=/tmp/prepare-mapr-image.out

# Extend the PATH.  This shouldn't be needed after Compute leaves beta.
PATH=/sbin:/usr/sbin:$PATH


# Helper utility to log the commands that are being run and
# save any errors to a log file
#	BEWARE : any error forces the script to exit
#		Since there are some some errors that we can live with,
#		this helper script is not used for all operations.
#
#	BE CAREFUL ... this function cannot handle command lines with
#	their own redirection.

c() {
    echo $* >> $LOG
    $* || {
	echo "============== $* failed at "`date` >> $LOG
	exit 1
    }
}

# The "customized" debian distributions often have configuration
# files that should not be overwritten during the upgrade process.
# We need the Dpkg::Options arg so that we don't get an error
# during the upgrad operation that will cause us to bail out
# right away.
function update_os_deb() {
	c apt-get update
	c apt-get upgrade -y -o Dpkg::Options::="--force-confdef,confold"
	c apt-get install -y nfs-common iputils-arping libsysfs2
	c apt-get install -y ntp

	c apt-get install -y sysstat
}

# For CentOS and Fedora, the GCE environment does not support 
# plugin modules to be added to the kernel ... so we don't
# need the module-init-tools package.   Moreover, on several
# occasions, updating that module cause strange behavior during
# instance launch.
function update_os_rpm() {
	c yum makecache
	c yum update -y --exclude=module-init-tools
	c yum install -y nfs-utils iputils libsysfs
	c yum install -y ntp ntpdate

	c yum install -y sysstat
}

# Make sure that NTP service is sync'ed and running
# Key Assumption: the /etc/ntp.conf file is reasonable for the 
#	hosting cloud platform.   We could shove our own NTP servers into
#	place, but that seems like a risk.
function update_ntp_config() {
	echo "  updating NTP configuration" >> $LOG

		# Make sure the service is enabled at boot-up
	if [ -x /etc/init.d/ntp ] ; then
		SERVICE_SCRIPT=/etc/init.d/ntp
		update-rc.d ntp enable
	elif [ -x /etc/init.d/ntpd ] ; then
		SERVICE_SCRIPT=/etc/init.d/ntpd
		chkconfig ntpd on
	else
		return 0
	fi

	$SERVICE_SCRIPT stop
	ntpdate pool.ntp.org
	$SERVICE_SCRIPT start

		# TBD: copy in /usr/share/zoneinfo file based on 
		# zone in which the instance is deployed
	zoneInfo=$(curl -f ${murl_top}/zone)
	curZone=`basename "${zoneInfo}"`
	curTZ=`date +"%Z"`
	echo "    Instance zone is $curZone; TZ setting is $curTZ" >> $LOG

		# Update the timezones we're sure of.
	TZ_HOME=/usr/share/zoneinfo/posix
	case $curZone in
		europe-west*)
			newTZ="CET"
			;;
		us-central*)
			newTZ="CST6CDT"
			;;
		us-east*)
			newTZ="EST5EDT"
			;;
		*)
			newTZ=${curTZ}
	esac

	if [ -n "${newTZ}"  -a  -f $TZ_HOME/$newTZ  -a  "${curTZ}" != "${newTZ}" ] 
	then
		echo "    Updating TZ to $newTZ" >> $LOG
		cp -p $TZ_HOME/$newTZ /etc/localtime
	fi
}

function update_ssh_config() {
	echo "  updating SSH configuration" >> $LOG

	# allow ssh via keys (some virtual environments disable this)
  sed -i 's/#AuthorizedKeysFile/AuthorizedKeysFile/' /etc/ssh/sshd_config

	# allow ssh password prompt (only for our dev clusters)
  sed -i 's/ChallengeResponseAuthentication .*no$/ChallengeResponseAuthentication yes/' /etc/ssh/sshd_config

	[ -x /etc/init.d/ssh ]   &&  /etc/init.d/ssh  restart
	[ -x /etc/init.d/sshd ]  &&  /etc/init.d/sshd restart
}

function update_os() {
  echo "Installing OS security updates and useful packages" >> $LOG

  if which dpkg &> /dev/null; then
    update_os_deb
  elif which rpm &> /dev/null; then
    update_os_rpm
  fi

	# raise TCP rbuf size
  echo 4096 1048576 4194304 > /proc/sys/net/ipv4/tcp_rmem  
#  sysctl -w vm.overcommit_memory=1  # swap behavior

  SELINUX_CONFIG=/etc/selinux/config
  [ -f $SELINUX_CONFIG ] && \
	sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' $SELINUX_CONFIG

	update_ntp_config
	update_ssh_config
}

# Whatever version of Java we want, we can do here.  The
# OpenJDK is a little easier because the mechanism for accepting
# the Oracle JVM EULA changes frequently.
#	NOTE: As of 2012, there is no way to automate the installation of
#	the Oracle JDK for RPM distributions; that only the OpenJDK is 
#	supported in an automated fashion.
#
#	Be sure to add the JAVA_HOME to our environment ... we'll use it later

function install_openjdk_deb() {
    echo "Installing OpenJDK packages (for deb distros)" >> $LOG

	c apt-get install -y x11-utils
	c apt-get install -y openjdk-7-jdk openjdk-7-doc 

	JAVA_HOME=/usr/lib/jvm/java-7-openjdk-amd64
	export JAVA_HOME
    echo "	JAVA_HOME=$JAVA_HOME" >> $LOG
}

function install_oraclejdk_deb() {
    echo "Installing Oracle JDK (for deb distros)" >> $LOG

	apt-get install -y python-software-properties
	add-apt-repository -y ppa:webupd8team/java
	apt-get update

	echo debconf shared/accepted-oracle-license-v1-1 select true | \
		debconf-set-selections
	echo debconf shared/accepted-oracle-license-v1-1 seen true | \
		debconf-set-selections

	apt-get install -y x11-utils
	apt-get install -y oracle-jdk7-installer

	JAVA_HOME=/usr/lib/jvm/java-7-oracle
	export JAVA_HOME
    echo "	JAVA_HOME=$JAVA_HOME"
}

function install_openjdk_rpm() {
    echo "Installing OpenJDK packages (for rpm distros)" >> $LOG

	c yum install -y java-1.7.0-openjdk java-1.7.0-openjdk-devel 
	c yum install -y java-1.7.0-openjdk-javadoc

	JAVA_HOME=/usr/lib/jvm/java-1.7.0-openjdk.x86_64
	export JAVA_HOME
    echo "	JAVA_HOME=$JAVA_HOME" >> $LOG
}

function install_oraclejdk_deb() {
    echo "Automated installation of Oracle JDK for rpm distros is not supported" >> $LOG
    echo "Falling back to OpenJDK" >> $LOG
	install_openjdk_rpm
}

# This has GOT TO SUCCEED ... otherwise the node is useless for MapR
function install_java() {
	echo Installing JAVA >> $LOG

	if which dpkg &> /dev/null; then
		install_openjdk_deb
	elif which rpm &> /dev/null; then
		install_openjdk_rpm
	fi

	if [ -x /usr/bin/java ] ; then
		echo Java installation complete >> $LOG

		if [ -n "${JAVA_HOME}" ] ; then
			echo updating /etc/profile.d/javahome.sh >> $LOG
			echo "JAVA_HOME=${JAVA_HOME}" >> /etc/profile.d/javahome.sh
			echo "export JAVA_HOME" >> /etc/profile.d/javahome.sh
		fi
	else
		echo Java installation failed >> $LOG
	fi
}

function add_mapr_user() {
	echo Adding/configuring mapr user >> $LOG
	id $MAPR_USER &> /dev/null
	[ $? -eq 0 ] && return $? ;

	echo "useradd -u 2000 -c MapR -m -s /bin/bash" >> $LOG
	useradd -u 2000 -c "MapR" -m -s /bin/bash $MAPR_USER 2> /dev/null
	if [ $? -ne 0 ] ; then
			# Assume failure was dup uid; try with default uid assignment
		echo "useradd returned $?; trying auto-generated uid" >> $LOG
		useradd -c "MapR" -m -s /bin/bash $MAPR_USER
	fi

	if [ $? -ne 0 ] ; then
		echo "Failed to create new user $MAPR_USER {error code $?}"
		return 1
	else
		passwd $MAPR_USER << passwdEOF > /dev/null
$MAPR_PASSWD
$MAPR_PASSWD
passwdEOF

	fi

		# Create sshkey for $MAPR_USER (must be done AS MAPR_USER)
	su $MAPR_USER -c "mkdir ~${MAPR_USER}/.ssh ; chmod 700 ~${MAPR_USER}/.ssh"
	su $MAPR_USER -c "ssh-keygen -q -t rsa -f ~${MAPR_USER}/.ssh/id_rsa -P '' "
	su $MAPR_USER -c "cp -p ~${MAPR_USER}/.ssh/id_rsa ~${MAPR_USER}/.ssh/id_launch"
	su $MAPR_USER -c "cp -p ~${MAPR_USER}/.ssh/id_rsa.pub ~${MAPR_USER}/.ssh/authorized_keys"
	su $MAPR_USER -c "chmod 600 ~${MAPR_USER}/.ssh/authorized_keys"
		
		# TBD : copy the key-pair used to launch the instance directly
		# into the mapr account to simplify connection from the
		# launch client.
	MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
#	LAUNCHER_SSH_KEY_FILE=$MAPR_USER_DIR/.ssh/id_launcher.pub
#	curl ${murl_top}/public-keys/0/openssh-key > $LAUNCHER_SSH_KEY_FILE
#	if [ $? -eq 0 ] ; then
#		cat $LAUNCHER_SSH_KEY_FILE >> $MAPR_USER_DIR/.ssh/authorized_keys
#	fi

		# Enhance the login with rational stuff
    cat >> $MAPR_USER_DIR/.bashrc << EOF_bashrc

CDPATH=.:$HOME
export CDPATH

# PATH updates based on settings in MapR env file
MAPR_HOME=${MAPR_HOME:-/opt/mapr}
MAPR_ENV=\${MAPR_HOME}/conf/env.sh
[ -f \${MAPR_ENV} ] && . \${MAPR_ENV} 
[ -n "\${JAVA_HOME}:-" ] && PATH=\$PATH:\$JAVA_HOME/bin
[ -n "\${MAPR_HOME}:-" ] && PATH=\$PATH:\$MAPR_HOME/bin

set -o vi

EOF_bashrc

	return 0
}

function setup_mapr_repo_deb() {
    MAPR_REPO_FILE=/etc/apt/sources.list.d/mapr.list
    MAPR_PKG="http://package.mapr.com/releases/v${MAPR_VERSION}/ubuntu"
    MAPR_ECO="http://package.mapr.com/releases/ecosystem/ubuntu"

    [ -f $MAPR_REPO_FILE ] && return ;

    echo Setting up repos in $MAPR_REPO_FILE
    cat > $MAPR_REPO_FILE << EOF_ubuntu
deb $MAPR_PKG mapr optional
deb $MAPR_ECO binary/
EOF_ubuntu
	
    apt-get update
}

function setup_mapr_repo_rpm() {
    MAPR_REPO_FILE=/etc/yum.repos.d/mapr.repo
    MAPR_PKG="http://package.mapr.com/releases/v${MAPR_VERSION}/redhat"
    MAPR_ECO="http://package.mapr.com/releases/ecosystem/redhat"

    [ -f $MAPR_REPO_FILE ] && return ;

    echo Setting up repos in $MAPR_REPO_FILE
    cat > $MAPR_REPO_FILE << EOF_redhat
[MapR]
name=MapR Version $MAPR_VERSION media
baseurl=$MAPR_PKG
enabled=1
gpgcheck=0
protected=1

[MapR_ecosystem]
name=MapR Ecosystem Components
baseurl=$MAPR_ECO
enabled=1
gpgcheck=0
protected=1
EOF_redhat

        # Metrics requires some packages in EPEL ... so we'll
        # add those repositories as well
        #   NOTE: this target will change FREQUENTLY !!!
    EPEL_RPM=/tmp/epel.rpm
    CVER=`lsb_release -r | awk '{print $2}'`
    if [ ${CVER%.*} -eq 5 ] ; then
        EPEL_LOC="epel/5/x86_64/epel-release-5-4.noarch.rpm"
    else
        EPEL_LOC="epel/6/x86_64/epel-release-6-8.noarch.rpm"
    fi

    wget -O $EPEL_RPM http://download.fedoraproject.org/pub/$EPEL_LOC
    [ $? -eq 0 ] && rpm --quiet -i $EPEL_RPM

    yum makecache
}


function setup_mapr_repo() {
  if which dpkg &> /dev/null; then
    setup_mapr_repo_deb
  elif which rpm &> /dev/null; then
    setup_mapr_repo_rpm
  fi
}


# Helper utility to update ENV settings in env.sh.
# Function is replicated in the configure-mapr-instance.sh script.
# Function WILL NOT override existing settings ... it looks
# for the default "#export <var>=" syntax and substitutes the new value
#
#	NOTE: this updates ONLY the env variables that are commented out
#	within env.sh.  It WILL NOT overwrite active settings.  This is
#	OK for our current deployment model, but may not be sufficient in
#	all cases.

MAPR_ENV_FILE=$MAPR_HOME/conf/env.sh
update-env-sh()
{
	[ -z "${1:-}" ] && return 1
	[ -z "${2:-}" ] && return 1

	AWK_FILE=/tmp/ues$$.awk
	cat > $AWK_FILE << EOF_ues
/^#export ${1}=/ {
	getline
	print "export ${1}=$2"
}
{ print }
EOF_ues

	cp -p $MAPR_ENV_FILE ${MAPR_ENV_FILE}.imager_save
	awk -f $AWK_FILE ${MAPR_ENV_FILE} > ${MAPR_ENV_FILE}.new
	[ $? -eq 0 ] && mv -f ${MAPR_ENV_FILE}.new ${MAPR_ENV_FILE}
}


install_mapr_packages() {
	mpkgs=""
	for pkg in `echo ${MAPR_PACKAGES//,/ }`
	do
		mpkgs="$mpkgs mapr-$pkg"
	done

	echo Installing MapR base components {$MAPR_PACKAGES} >> $LOG
	if which dpkg &> /dev/null; then
		c apt-get install -y --force-yes $mpkgs
	elif which rpm &> /dev/null; then
		c yum install -y $mpkgs
	fi

	echo Configuring $MAPR_ENV_FILE  >> $LOG
	update-env-sh MAPR_HOME $MAPR_HOME
	update-env-sh JAVA_HOME $JAVA_HOME
}


#
# Disable starting of MAPR, and clean out the ID's that will be intialized
# with the full install. 
#	NOTE: the instantiation process from an image generated via
#	this script MUST recreate the hostid and hostname files
#
function disable_mapr_services() 
{
	echo Temporarily disabling MapR services >> $LOG
	c mv -f $MAPR_HOME/hostid    $MAPR_HOME/conf/hostid.image
	c mv -f $MAPR_HOME/hostname  $MAPR_HOME/conf/hostname.image

	if which dpkg &> /dev/null; then
		c update-rc.d -f mapr-warden remove
		echo $MAPR_PACKAGES | grep -q zookeeper
		if [ $? -eq 0 ] ; then
			c update-rc.d -f mapr-zookeeper remove
		fi
	elif which rpm &> /dev/null; then
		c chkconfig mapr-warden off
		echo $MAPR_PACKAGES | grep -q zookeeper
		if [ $? -eq 0 ] ; then
			c chkconfig mapr-zookeeper off
		fi
	fi
}


# High level wrapper around the above scripts. 
# Ideally, we should handle errors correctly here.
main() {
	echo "Image creation started at "`date` >> $LOG
	
	update_os
	install_java

	add_mapr_user
	setup_mapr_repo
	install_mapr_packages
	disable_mapr_services

	echo "Image creation completed at "`date` >> $LOG
	echo IMAGE READY >> $LOG
	return 0
}

main
exitCode=$?

# Save of the install log to ~${MAPR_USER}; some cloud images
# use AMI's that automatically clear /tmp with every reboot
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
if [ -n "${MAPR_USER_DIR}"  -a  -d ${MAPR_USER_DIR} ] ; then
		cp $LOG $MAPR_USER_DIR
		chmod a-w ${MAPR_USER_DIR}/`basename $LOG`
		chown ${MAPR_USER}:`id -gn ${MAPR_USER}` \
			${MAPR_USER_DIR}/`basename $LOG`
fi

exit $exitCode

