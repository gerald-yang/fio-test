#!/bin/bash

set -x

msg_prefix="(vm)"

function extract_config {
	echo "Extract config.json"
	ARCHIVE=$(awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' $0)
	tail -n+$ARCHIVE $0 | tar xv
}

extract_config

pass="passw0rd"
eval "$(ssh-agent -s)"
expect << EOF
	spawn ssh-add /root/.ssh/id_rsa
	expect "Enter passphrase"
	send "$pass\r"
	expect eof
EOF

LOGDIR="fiolog"

if [ -z "$1" ]; then
	CONFIG_FILE="config.json"
else
	CONFIG_FILE="$1"
fi

# check config file
if ! [ -f "$CONFIG_FILE" ]; then
	echo "$msg_prefix Error: can not find $CONFIG_FILE"
	exit 1
fi

# create log folder
rm -rf "$LOGDIR"
mkdir -p "$LOGDIR"

echo "$msg_prefix Start testing"

disknode=$(jq -r ".disknode" "$CONFIG_FILE")
disksize=$(jq -r ".disksize" "$CONFIG_FILE")
(( dd_count = disksize * 1024 ))

initial_random_write="false"
group_iter=0
while true;
do
	groupname=$(jq -r ".testGroup[$group_iter].testname" "$CONFIG_FILE")

	if [ "$groupname" = "null" ]; then
		echo "$msg_prefix All test groups done"
		break
	fi

	# create group test folder
	mkdir -p "$LOGDIR/$groupname"

	echo "$msg_prefix Start test group: $groupname"
	iter=0
	while true;
	do
		# get test parameters from json file
		name=$(jq -r ".testGroup[$group_iter].testitem[$iter].name" "$CONFIG_FILE")
		vm=$(jq -r ".testGroup[$group_iter].testitem[$iter].vm" "$CONFIG_FILE")
		numjobs=$(jq -r ".testGroup[$group_iter].testitem[$iter].numjobs" "$CONFIG_FILE")
		iodepth=$(jq -r ".testGroup[$group_iter].testitem[$iter].iodepth" "$CONFIG_FILE")
		rwtype=$(jq -r ".testGroup[$group_iter].testitem[$iter].rwtype" "$CONFIG_FILE")
		rwmixread=$(jq -r ".testGroup[$group_iter].testitem[$iter].rwmixread" "$CONFIG_FILE")
		blocksize=$(jq -r ".testGroup[$group_iter].testitem[$iter].blocksize" "$CONFIG_FILE")
		runtime=$(jq -r ".testGroup[$group_iter].testitem[$iter].runtime" "$CONFIG_FILE")
		delay=$(jq -r ".testGroup[$group_iter].testitem[$iter].delay" "$CONFIG_FILE")

		if [ "$name" = "null" ]; then
			echo "$msg_prefix All test items done"
			break
		fi

		if [ "$rwtype" = "randread" ] || [ "$rwtype" = "randrw" ] || [ "$rwtype" = "read" ] || [ "$rwtype" = "rw" ]; then
			if [ "$initial_random_write" = "false" ]; then
				echo "$msg_prefix Write random data to $disknode before testing"
				iter_addr=0
				while true;
				do
					address=$(jq -r ".testGroup[$group_iter].testitem[$iter].address[$iter_addr]" "$CONFIG_FILE")
					if [ "$address" = "null" ]; then
						break
					fi

					if [ ! -e "$disknode" ]; then
						echo "$msg_prefix Error: no such device: $disknode"
						exit 1
					fi
		
					ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$address" dd if=/dev/urandom of="$disknode" bs=1M count="$dd_count" status=progress &
		
					pids[$iter_addr]=$!
					echo "$msg_prefix Pid: ${pids[$iter_addr]}"
		
					(( iter_addr = iter_addr + 1 ))
				done
		
				# wait for tests on different VMs to complete
				echo "$msg_prefix Waiting for writing random data"
				for pid in ${pids[*]};
				do
					wait $pid
				done

				initial_random_write="true"
			fi
		fi

		# create a folder for each test
		mkdir -p "$LOGDIR/$groupname/$name"
	
		echo "$msg_prefix Running test item: $name"
	
		# run test on all VMs simultaneously
		iter_addr=0
		while true;
		do
			address=$(jq -r ".testGroup[$group_iter].testitem[$iter].address[$iter_addr]" "$CONFIG_FILE")
			if [ "$address" = "null" ]; then
				break
			fi
	
			if [ ! -e "$disknode" ]; then
				echo "$msg_prefix Error: no such device: $disknode"
				exit 1
			fi
	
			FIO_OUTPUT[$iter_addr]="fio_${name}_${address}_log"
			FIO_IOPS_LOG[$iter_addr]="fio_${name}_${address}_log_vdc_${rwtype}_${blocksize}_${iodepth}iodepth_${numjobs}numjobs_${runtime}s"
	
			if [ "$rwmixread" = "null" ]; then
				ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$address" fio --name="$name" --rw="$rwtype" --bs="$blocksize" --runtime="$runtime" --ioengine=libaio --iodepth="$iodepth" --numjobs="$numjobs" --filename="$disknode" --direct=1 --group_reporting --time_based=1 --output="${FIO_OUTPUT[$iter_addr]}" --write_iops_log="${FIO_IOPS_LOG[$iter_addr]}" --log_avg_msec=1000 --group_reporting --eta-newline 1 &
			else
				ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$address" fio --name="$name" --rw="$rwtype" --rwmixread="$rwmixread" --bs="$blocksize" --runtime="$runtime" --ioengine=libaio --iodepth="$iodepth" --numjobs="$numjobs" --filename="$disknode" --direct=1 --group_reporting --time_based=1 --output="${FIO_OUTPUT[$iter_addr]}" --write_iops_log="${FIO_IOPS_LOG[$iter_addr]}" --log_avg_msec=1000 --group_reporting --eta-newline 1 &
			fi	

			pids[$iter_addr]=$!
			echo "$msg_prefix Pid: ${pids[$iter_addr]}"
	
			(( iter_addr = iter_addr + 1 ))
		done
	
		# wait for tests on different VMs to complete
		echo "$msg_prefix Waiting for $name to complete"
		for pid in ${pids[*]};
		do
			wait $pid
		done
	
		# copy out logs from VMs
		iter_addr=0
		while true;
		do
			address=$(jq -r ".testGroup[$group_iter].testitem[$iter].address[$iter_addr]" "$CONFIG_FILE")
			if [ "$address" = "null" ]; then
				break
			fi
	
			scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$address:~/${FIO_OUTPUT[$iter_addr]}" "$LOGDIR/$groupname/$name/"
			scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$address:~/${FIO_IOPS_LOG[$iter_addr]}_iops*.log" "$LOGDIR/$groupname/$name/"
	
			(( iter_addr = iter_addr + 1 ))
		done
		
		echo "$msg_prefix Test item $name done"
	
		(( iter = iter + 1 ))

		# sleep for a while between tests if necessary
		sleep "$delay"
	done

	(( group_iter = group_iter + 1 ))
done

exit 0

__ARCHIVE_BELOW__
