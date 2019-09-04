#!/bin/bash
# Aims to replace a single instance
set -e
error_trap() {
    echo "replace ($INSTANCE_ID): Error on line $1"
}
trap 'error_trap $LINENO' ERR

# Config
INSTANCE_ID=$1
if [ -z "$CHECK_NAMESPACE" ]; then
    CHECK_NAMESPACE="devtools-builds" # kube namespace to check for important pods
fi
if [ -z "$CHECK_POD_KEYWORD" ]; then
    CHECK_POD_KEYWORD="runner" # keyword to use to find important pods
fi
if [ -z "$CHECK_WAIT_TIMEOUT" ]; then
    CHECK_WAIT_TIMEOUT="1080" # timeout to wait for node to drain, give it 18 mins, bit less than block remaining
fi

INSTANCE_DETAIL=$(aws ec2 describe-instances --filter Name=instance-id,Values=$INSTANCE_ID)
ASG_NAME=$(echo "$INSTANCE_DETAIL" | jq ".Reservations[].Instances[].Tags[]|select(.Key==\"SpotSysTemplateASG\")|.Value" | cut -d'"' -f 2)
INSTANCE_IDENTIFIER=$(echo "$INSTANCE_DETAIL" | jq ".Reservations[].Instances[].Tags[]|select(.Key==\"SpotSysIdentifier\")|.Value" | cut -d'"' -f 2)
INSTANCE_GENERATION=$(echo "$INSTANCE_DETAIL" | jq ".Reservations[].Instances[].Tags[]|select(.Key==\"SpotSysGeneration\")|.Value" | cut -d'"' -f 2)
if [ -z "$ASG_NAME" ] || [ -z "$INSTANCE_IDENTIFIER" ]; then
	echo "replace ($INSTANCE_ID): Couldn't find ASG or Instance ID? Weird, failing.."
	exit 1
fi

if ! $SCRIPT_DIR/cordon.sh $INSTANCE_ID; then
	echo "replace: Failed cordoning $INSTANCE_ID"
	exit 1
fi

# check for pods to complete and then we can terminate.
START_TIME=$(date +%s)
while true; do
	CURRENT_TIME=$(date +%s)
    if [[ $((CURRENT_TIME-$CHECK_WAIT_TIMEOUT)) -gt $START_TIME ]]; then
    	echo "replace ($INSTANCE_ID): Graceful replacement timed out after $CHECK_WAIT_TIMEOUT seconds waiting for pods to drain.. giving up.."
    	break
	fi

	POD_COUNT=$(kubectl get pods -n $CHECK_NAMESPACE -o wide | grep $NODE_NAME | grep $CHECK_POD_KEYWORD | grep -c "" | cat)
	if [ $POD_COUNT -gt 0 ]; then
		echo "replace ($INSTANCE_ID): Node has $POD_COUNT matching pods still, will keep waiting.."
	else
		echo "replace ($INSTANCE_ID): Node has no more matching pods, safe to replace.."
		# node has no more pods, safe to replace
		echo "replace ($INSTANCE_ID): Terminating instance: $INSTANCE_ID"
		aws ec2 terminate-instances --instance-ids $INSTANCE_ID
		break
	fi

	sleep 15
done

# instance is drained or timed out, safe to replace, we will just create a new one and old one will self-terminate on block expiry
echo "replace ($INSTANCE_ID): Creating replacement instance.."
$SCRIPT_DIR/create.sh "$ASG_NAME" "$INSTANCE_IDENTIFIER" "$((INSTANCE_GENERATION + 1))"

echo "replace ($INSTANCE_ID): Replacement has started, done."