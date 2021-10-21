#!/bin/bash
# Tries to maintain existing spot block instances by cordoning and recycling before their block duration is exceeded.
set -e
error_trap() {
    echo "replace ($INSTANCE_ID): Error on line $1"
}
trap 'error_trap $LINENO' ERR

# Config
if [ -z "$ASG_NAME" ]; then
	echo "No ASG Name specified!"
	exit 1
fi

if [ -z "$REPLACEMENT_LIMIT_SECONDS" ]; then
	REPLACEMENT_LIMIT_SECONDS=1200
fi

if [ -z "$OPERATION_START" ]; then
	OPERATION_START="08:00"
fi

if [ -z "$OPERATION_END" ]; then
	OPERATION_END="15:59"
fi

if [ -z "$OPERATION_DOW" ]; then
	OPERATION_DOW="Mon,Tue,Wed,Thu,Fri"
fi

if [ -z "$TARGET_INSTANCE_COUNT" ]; then
	TARGET_INSTANCE_COUNT=15
fi

if [ -z "$CREATION_DELAY_SECONDS" ]; then
	CREATION_DELAY_SECONDS=300
fi

if [ -z "$OPERATION_TZ" ]; then
	OPERATION_TZ="Australia/Melbourne"
fi

# Script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LAST_CREATED_TIMESTAMP=""

while true; do
	CURRENT_HOURMINUTE=$(TZ="$OPERATION_TZ" date +%H:%M)
	CURRENT_DOW=$(TZ="$OPERATION_TZ" date +%a)
	OUT_OF_HOURS=false

	if [[ $CURRENT_HOURMINUTE < "$OPERATION_START" ]] || [[ $CURRENT_HOURMINUTE > "$OPERATION_END" ]] || [[ $OPERATION_DOW != *"$CURRENT_DOW"* ]]; then
		echo "maintain: Currently outside the hours of operation no new instances will be started, hours are $OPERATION_START to $OPERATION_END ($OPERATION_DOW), it is currently $CURRENT_DOW at $CURRENT_HOURMINUTE"
		OUT_OF_HOURS=true
	fi

	printf "maintain: Finding existing spot instances created off $ASG_NAME with <$REPLACEMENT_LIMIT_SECONDS seconds remaining.. "
	INSTANCE_IDS=$(aws ec2 describe-instances --filter Name=tag:SpotSysTemplateASG,Values=$ASG_NAME Name=instance-state-name,Values=running | jq ".Reservations[].Instances[].InstanceId" | cut -d'"' -f 2)
	INSTANCE_COUNT=$(printf "$INSTANCE_IDS" | grep -c "i" | cat)
	printf "found $INSTANCE_COUNT instance(s)\n"

	# try and replace existing instances or cordon existing ones
	for INSTANCE_ID in $(echo $INSTANCE_IDS)
	do
		NOW=$(date +%s)
		INSTANCE_EXPIRY=$(aws ec2 describe-instances --filter Name=instance-id,Values=$INSTANCE_ID | jq ".Reservations[].Instances[].Tags[]|select(.Key==\"SpotSysExpired\")|.Value" | cut -d'"' -f 2)
		INSTANCE_EXPIRES_IN=$((INSTANCE_EXPIRY - NOW))

		if [ $INSTANCE_EXPIRES_IN -lt $REPLACEMENT_LIMIT_SECONDS ]; then
			if [ "$OUT_OF_HOURS" == "true" ]; then
				echo "maintain: $INSTANCE_ID expires in $INSTANCE_EXPIRES_IN seconds, cordoning.."
				{
					set +e
					echo "maintain: Cordoning.. $INSTANCE_ID"
					if ! $SCRIPT_DIR/cordon.sh $INSTANCE_ID; then
						echo "maintain: Failed cordoning $INSTANCE_ID"
					fi
				} &
			else
				echo "maintain: $INSTANCE_ID expires in $INSTANCE_EXPIRES_IN seconds, replacing.."
				{
					set +e
					echo "maintain: Replacing.. $INSTANCE_ID"
					if ! $SCRIPT_DIR/replace.sh $INSTANCE_ID; then
						echo "maintain: Failed replacing $INSTANCE_ID"
					fi
				} &
			fi
		fi
	done

	#try and create instances if we are below target and not out of hours
	if [ $INSTANCE_COUNT -lt $TARGET_INSTANCE_COUNT ] && [ "$OUT_OF_HOURS" == "false" ]; then
		CURRENT_TIMESTAMP=$(date +%s)
		# if we have no last created timestamp, or the last time we created was more than N seconds ago, create a new instance
		if [ -z "$LAST_CREATED_TIMESTAMP" ] || [ $LAST_CREATED_TIMESTAMP -lt $((CURRENT_TIMESTAMP - CREATION_DELAY_SECONDS)) ]; then
			LAST_CREATED_TIMESTAMP=$CURRENT_TIMESTAMP
			echo "maintain: Instance count ($INSTANCE_COUNT) is below target count ($TARGET_INSTANCE_COUNT), trying to create a new instance.."
			{
				set +e
				if ! $SCRIPT_DIR/create.sh "$ASG_NAME"; then
					echo "maintain: Failed creating instance"
				fi
			} &
		else
			echo "maintain: Instance count ($INSTANCE_COUNT) is below target count ($TARGET_INSTANCE_COUNT), created instance recently, skipping.."
		fi

	fi

	echo "maintain: Done checking, waiting for 60 secs.."
	sleep 60
done
