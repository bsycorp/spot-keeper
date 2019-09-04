#!/bin/bash
# Aims to cordon a single instance
set -e
error_trap() {
    echo "cordon ($INSTANCE_ID): Error on line $1"
}
trap 'error_trap $LINENO' ERR

# Config
INSTANCE_ID=$1

# Script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "cordon ($INSTANCE_ID): Trying to cordon $INSTANCE_ID"

NODE_NAME=$(aws ec2 describe-instances --filter Name=instance-id,Values=$INSTANCE_ID | jq ".Reservations[].Instances[].PrivateDnsName" | cut -d'"' -f 2)
if [ -z "$NODE_NAME" ]; then
	echo "cordon ($INSTANCE_ID): Couldn't find node name! Might have been terminated already?"
	exit 1
fi

echo "cordon ($INSTANCE_ID): Found node name: $NODE_NAME, checking cordon.."

NODE_DESCRIPTION=$(kubectl get node | grep $NODE_NAME | cat)
if [ -z "$NODE_DESCRIPTION" ]; then
	echo "cordon ($INSTANCE_ID): Couldn't find registered node in kube! Might have been terminated already?"
	exit 1
fi

# check and optionally mark instance as being cordoned, so we don't try and cordon it multiple times
ALREADY_BEING_DRAINED=$(aws ec2 describe-instances --filter Name=instance-id,Values=$INSTANCE_ID | jq ".Reservations[].Instances[].Tags[]|select(.Key==\"SpotSysDraining\")|.Value" | cut -d'"' -f 2)
if [ ! -z "$ALREADY_BEING_DRAINED" ]; then
	echo "cordon ($INSTANCE_ID): Instance $INSTANCE_ID is already being replaced, ignoring.."
	exit 0
else
	aws ec2 create-tags --resources $INSTANCE_ID --tags Key=SpotSysDraining,Value=true
fi

# cordon node, no more pods will be scheduled!
kubectl cordon $NODE_NAME | cat