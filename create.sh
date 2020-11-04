#!/bin/bash
# Create spot instance script like a given ASG instance, try and copy as many settings as practical from the ASG and launch config, then create a spot block to match
set -e
error_trap() {
    echo "replace ($INSTANCE_ID): Error on line $1"
}
trap 'error_trap $LINENO' ERR

# Config
WAIT_TIMEOUT="30" # timeout to wait for spot reservation to get an instance
TAG_NAMES="KubernetesCluster,Purpose,k8s.io/role/node,Cluster,Datadog,Env,Instance,ProxyUser,kops.k8s.io/instancegroup"

ASG_NAME="$1"
if [ -z "$ASG_NAME" ]; then
  echo "create: ASG name is required to create instances from"
  exit 1
fi

INSTANCE_IDENTIFIER="$2" # a value we tag the instance with to uniquely identify this requested instance, helps when replacing
if [ -z "$INSTANCE_IDENTIFIER" ]; then
  INSTANCE_IDENTIFIER=$(head -c 10 /dev/urandom | sha1sum | cut -c 1-6)
fi

INSTANCE_GENERATION="$3"
if [ -z "$INSTANCE_GENERATION" ]; then
  INSTANCE_GENERATION="1"
fi

if [ -z "$BLOCK_DURATION" ]; then
  BLOCK_DURATION="240" # number of minutes that the spot reservation will guarantee 
fi

if [ -z "$ADDITIONAL_INSTANCE_TYPES" ]; then
  ADDITIONAL_INSTANCE_TYPES="" #"m5.4xlarge"
fi

# Script
echo "create: Looking up details from target ASG: $ASG_NAME.."
ASG_DETAIL=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG_NAME")
LaunchConfigurationName=$(echo "$ASG_DETAIL" | jq .AutoScalingGroups[0].LaunchConfigurationName | cut -d'"' -f 2)
VPCZoneIdentifier=$(echo "$ASG_DETAIL" | jq .AutoScalingGroups[0].VPCZoneIdentifier | cut -d'"' -f 2)
AutoScalingGroupName=$(echo "$ASG_DETAIL"  | jq .AutoScalingGroups[0].AutoScalingGroupName)
LAUNCH_CONFIG_DETAIL=$(aws autoscaling describe-launch-configurations --launch-configuration-names "$LaunchConfigurationName")
UserData=$(echo "$LAUNCH_CONFIG_DETAIL" | jq .LaunchConfigurations[0].UserData)
InstanceType=$(echo "$LAUNCH_CONFIG_DETAIL" | jq .LaunchConfigurations[0].InstanceType | cut -d'"' -f 2)
IamInstanceProfile=$(echo "$LAUNCH_CONFIG_DETAIL" | jq .LaunchConfigurations[0].IamInstanceProfile | cut -d'"' -f 2)
ImageId=$(echo "$LAUNCH_CONFIG_DETAIL" | jq .LaunchConfigurations[0].ImageId)
SecurityGroups=$(echo "$LAUNCH_CONFIG_DETAIL" | jq .LaunchConfigurations[0].SecurityGroups)
AwsAccountId=$(aws sts get-caller-identity --output text --query 'Account')

# generate permutations to walk through when attempting to create a spot block, hopefully one of them works.
ALL_INSTANCE_TYPES=$(printf "$InstanceType\n$ADDITIONAL_INSTANCE_TYPES" | paste -sd,)
rm -f /tmp/subnet-instance-combos | cat
for subnet in $(echo $VPCZoneIdentifier | tr "," "\n"); do
  for instanceType in $(echo "$ALL_INSTANCE_TYPES" | tr "," "\n"); do
    echo "$subnet,$instanceType" >> /tmp/subnet-instance-combos
  done
done

# loop combinations until we get a fulfillment
for combination in $(cat /tmp/subnet-instance-combos | sort --random-sort); do
  subnet=$(echo $combination | cut -d',' -f 1)
  InstanceType=$(echo $combination | cut -d',' -f 2)

cat << EOF > /tmp/spec.json
  {
    "ImageId": $ImageId,
    "SecurityGroupIds": $SecurityGroups,
    "InstanceType": "$InstanceType",
    "SubnetId": "$subnet",
    "IamInstanceProfile": {
        "Arn": "arn:aws:iam::$AwsAccountId:instance-profile/$IamInstanceProfile"
    },
    "BlockDeviceMappings": [
      {
        "DeviceName": "/dev/xvda",
        "Ebs": {
          "DeleteOnTermination": true,
          "VolumeSize": 128,
          "VolumeType": "gp2"
        }
     }
    ],
    "UserData": $UserData
  }
EOF

  echo "create: Trying to request new spot instance for $InstanceType with duration $BLOCK_DURATION mins that looks like $ASG_NAME in subnet $subnet.."
  # set stupidly high spot price as we are using blocks and can't actually set a price, but its required in the cli =(
  RESERVATION_ID=$(aws ec2 request-spot-instances --spot-price "5.00" --block-duration-minutes $BLOCK_DURATION --instance-count 1 --launch-specification file:///tmp/spec.json | jq .SpotInstanceRequests[0].SpotInstanceRequestId | cut -d'"' -f 2)
  echo "create: Got Reservation ID: $RESERVATION_ID"

  START_TIME=$(date +%s)
  echo "create: Checking reservation for fulfilled instance.. ($WAIT_TIMEOUT second timeout)"
  while true; do
      sleep 1
      CURRENT_TIME=$(date +%s)
      if [[ $((CURRENT_TIME-$WAIT_TIMEOUT)) -gt $START_TIME ]]; then
          echo "create: Spot reservation timeout, didn't get instance after $WAIT_TIMEOUT seconds.. cancelling.."
          aws ec2 cancel-spot-instance-requests --spot-instance-request-ids $RESERVATION_ID
          echo "create: Spot reservation cancelled. Trying another subnet.."
          break
      fi

      INSTANCE_ID=$(aws ec2 describe-instances --filters Name=spot-instance-request-id,Values=$RESERVATION_ID | jq .Reservations[].Instances[].InstanceId | cut -d'"' -f 2)
      if [ ! -z "$INSTANCE_ID" ]; then #if we have an instance id, then we have an instance! success!
        break
      fi
  done
  if [ -z "$INSTANCE_ID" ]; then
    continue # reservation cancelled, try another subnet/type
  fi

  echo "create: Found instance for reservation with id: $INSTANCE_ID, tagging.."
  CREATED_TIME=$(date +%s)
  EXPIRED_TIME=$((CREATED_TIME+(BLOCK_DURATION*60)))
  # tag with spot system tags, used during the maintain phase
  aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=spot$ASG_NAME Key=SpotSysTemplateASG,Value=$ASG_NAME Key=SpotSysIdentifier,Value=$INSTANCE_IDENTIFIER Key=SpotSysGeneration,Value=$INSTANCE_GENERATION Key=SpotSysCreated,Value=$CREATED_TIME Key=SpotSysExpired,Value=$EXPIRED_TIME
  # also copy some whitelisted tags across from the ASG, mostly to make kube happy. Be nice to do all tagging in one step, but is way more complex so simple and slower it is!
  for TAG_NAME in $(echo $TAG_NAMES | tr "," "\n")
  do
    TAG_VALUE=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME | jq ".AutoScalingGroups[0].Tags[]|select(.Key==\"$TAG_NAME\")|.Value" | cut -d'"' -f 2)
    aws ec2 create-tags --resources $INSTANCE_ID --tags Key=$TAG_NAME,Value=$TAG_VALUE
  done
  echo "create: Create successful."
  exit 0

done

echo "create: Exhausted create options, giving up.."
exit 1
