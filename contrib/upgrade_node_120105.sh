#!/bin/bash

RELEASEFILE="https://github.com/coin2fly/coin2flycore/releases/download/v0.12.1.5/coin2flycore-0.12.1.5-linux64.tar.gz"
SENTINELGIT="https://github.com/coin2fly/sentinelLinux.git" # leave empty if coin has no sentinel

daemon="coin2flyd"
cli="coin2fly-cli"
stopcli="stop"
archive_path="coin2flycore-0.12.1.5/bin/"
core_dir=".coin2flycore"
config_path="$core_dir/coin2fly.conf"
node_user="coin2fly"
mainnet="12225"
disablewallet="" # risky, a lot of coins that implement zerocoin/darksend functionality break the daemon with this

# this variable is used to keep track of the upgrades to our environment
checkpoint="20180323"
installer_checkpoint="/home/$node_user/$core_dir/.installer_checkpoint"

# other variables
DISTRO=$(lsb_release -s -c)

# environment setup, make it pretty
tred=$(tput setaf 1); tgreen=$(tput setaf 2); tyellow=$(tput setaf 3); tblue=$(tput setaf 4); tmagenta=$(tput setaf 5); tcyan=$(tput setaf 6); treset=$(tput sgr0); tclear=$(tput clear); twbg=$(tput setab 7)

echo $tclear
# checking for current user id, we should be running as root
if (( EUID != 0 )); then
	echo -e "$tred""I need to be root to run this. Please switch to root with $twbg sudo -i $treset$tred or log in directly as root, then run the command again.$treset\n"
	exit 1
fi

# checking for a running daemon of the coin, if there is none, this is either the wrong coin, or the initial setup script hasn't been run
BINPID=$(pidof $daemon)

if (( BINPID )); then
	echo "Found $tcyan$daemon$treset running with:"
	echo " * PID: $tyellow$BINPID$treset."
	BINPATH=$(readlink -f /proc/"$BINPID"/exe)
	echo " * Path: $tyellow$BINPATH$treset."
	BINUID=$(awk '/^Uid:/{print $2}' /proc/"$BINPID"/status)
	BINUSER=$(getent passwd "$BINUID" | awk -F: '{print $1}')
	echo " * Running as: $tyellow$BINUSER$treset."
	echo " * Running under: $tyellow$DISTRO$treset."
	echo "------------------------------"
	if [[ "$BINUSER" != "$node_user" ]]; then
		echo "The user that this $tyelow$daemon$treset is running does not match what we expect. Aborting."
		exit 1
	fi
else
	echo "We are unable to find a $tyellow$daemon$treset running. Aborting."
	exit 1
fi

if [[ -f "$installer_checkpoint" ]]; then
	# ok, a checkpoint exists, we only had one so far, so it should be before this one
	current_checkpoint=$(< $installer_checkpoint)
	if (( current_checkpoint >= checkpoint )); then
		echo -e "\nYou are at the current checkpoint. You do not need this update, you already have it.\n"
		exit 1
	fi
fi

function update_wrapper {
	# setting up wrappers so the user never calls the binary directly as root
	cat <<- EOF > /usr/local/bin/"$daemon"
	#!/bin/bash
	
	echo -e "\n"
	echo -e "Please$tred do not$treset run the daemon manually. Use$tyellow systemctl start $daemon$treset as$tred root$treset to start it (or$tgreen restart$treset)."
	echo -e "\n"
	
	if (( EUID == 0 )); then
	
		if [[ "\$@" =~ "reindex" ]]; then
			echo "It seems that you are trying to reindex the blockchain database. Please use$tyellow systemctl start $daemon-reindex$treset to do this."
			echo "I will do this for you this time."
			exec systemctl start $daemon-reindex
			exit 0
		fi
		
		echo "Please do not attempt to run the daemon as$tred root$treset. Switch to the $tgreen$node_user$treset user with:$tyellow su - $node_user$treset."
		
		if (( \$# == 0 )); then
			exec su - $node_user -c "/usr/bin/$daemon"
		else
			printf -v string '%q ' "\$@"; exec su - $node_user -c "/usr/bin/$daemon \$string"
		fi
		
	else
	
		if (( $(pidof $daemon) )); then
			echo "$tcyan$daemon is already running."
			exit 1
		fi
		
		if (( \$# == 0 )); then
			exec /usr/bin/$daemon
		else
			printf -v string '%q ' "\$@"; exec /usr/bin/$daemon "\$string"
		fi
		
	fi
	EOF
	
	chmod +x /usr/local/bin/"$daemon"
}

function update_systemd {

	cat <<- EOF > /lib/systemd/system/"$daemon".service
	[Unit]
	Description=$daemon's masternode daemon
	After=network.target
	
	[Service]
	User=$node_user
	Group=$node_user
	Type=forking
	ExecStart=/usr/bin/$daemon -daemon $disablewallet
	ExecStop=/usr/bin/$cli $stopcli
	OnFailure=$daemon-reindex.service
	Restart=always
	TimeoutStopSec=60s
	TimeoutStartSec=30s
	StartLimitInterval=120s
	StartLimitBurst=5
	
	[Install]
	WantedBy=multi-user.target
	EOF
	
	cat <<- EOF > /lib/systemd/system/"$daemon"-reindex.service
	[Unit]
	Description=$daemon's reindex
	After=network.target
	OnFailure=$daemon.service
	Conflicts=$daemon.service
	
	[Service]
	User=$node_user
	Group=$node_user
	Type=forking
	ExecStart=/usr/bin/$daemon -daemon -reindex $disablewallet
	ExecStop=/usr/bin/$cli $stopcli
	Restart=always
	TimeoutStopSec=60s
	TimeoutStartSec=30s
	StartLimitInterval=120s
	StartLimitBurst=5
	
	[Install]
	WantedBy=multi-user.target
	EOF
	
	systemctl daemon-reload
	systemctl enable "$daemon"
	systemctl restart "$daemon"
}

function download_unpack_install {
	# grabbing the new release
	FILENAME=$(basename "$RELEASEFILE")
	echo "Downloading package:"
	curl -LJO -k "$RELEASEFILE" -o "$FILENAME"

	# unpacking in /usr/bin, we're unpacking only the daemon and cli, don't need the rest
	tar -C /usr/bin/ -xzf "$FILENAME" --strip-components 2 "$archive_path$daemon" "$archive_path$cli"
	# remove the archive, keep it clean
	rm -f "$FILENAME"

	# making sure the files have the correct permission, maybe someone cross-compiled and moved to a non-posix filesystem
	chmod +x /usr/bin/{"$daemon","$cli"}
	
}

function stop_services {
	echo "Stopping running services."
	systemctl stop coin2flyd-reindex
	systemctl stop coin2flyd
	sleep 3
	killall -9 coin2flyd 2>/dev/null
}

function install_cronjob {
	echo "Installing extra cronjob."
	
	crontab -l | { cat; echo "SHELL=/bin/bash" ;} | crontab -
	crontab -l | { cat; echo "*/15 * * * * (( (\$(curl -s http://explorer.coin2fly.com/api/getblockcount) - \$(coin2fly-cli getblockcount)) > 10 )) && systemctl restart coin2flyd-reindex" ;} | crontab -
}

stop_services
download_unpack_install
install_cronjob
update_wrapper
update_systemd

# set checkpoint
echo "$checkpoint" > "$installer_checkpoint"
echo -e "\n"
echo "We have updated to version$tyellow v0.12.1.5$treset."
echo -e "\n"
echo "We have updated some systemd unit files."
echo "$tred""IF$treset you ever need to$tmagenta reindex$treset the blockchain - please use:$tyellow systemctl start $daemon-reindex$treset"
echo -e "\n"
echo "Done. Updated to checkpoint: $tyellow$checkpoint$treset".
