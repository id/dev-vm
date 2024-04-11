#!/usr/bin/env bash

set -euo pipefail

[ "${DEBUG:-0}" == "1" ] && set -x

INSTANCE_NAME=${1:-dev-vm}
REGION=${REGION:-eu-north-1}
AVAILABILITY_ZONE=${AVAILABILITY_ZONE:-$REGION"a"}
AMI_NAME_FILTER=${AMI_NAME_FILTER:-'dev-vm-*'}
AMI_ID=$(aws ec2 describe-images \
             --filters "Name=name,Values=${AMI_NAME_FILTER}" \
             --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' \
             --output text --region $REGION)

VPC_ID=${VPC_ID:-$(aws ec2 describe-vpcs \
                       --query 'Vpcs[?IsDefault==`true`].[VpcId]' \
                       --output text --region $REGION)}
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AVAILABILITY_ZONE" \
  --query 'Subnets[0].SubnetId' \
  --output text --region $REGION)

SECURITY_GROUP_NAME=${SECURITY_GROUP_NAME:-dev-vm-sg}
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=tag:Name,Values=${SECURITY_GROUP_NAME}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text --region $REGION)

if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" = None ]]; then
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name $SECURITY_GROUP_NAME \
    --description "Security group for dev VMs" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text --region $REGION)
  aws ec2 wait security-group-exists --group-ids $SECURITY_GROUP_ID --region $REGION
fi
aws ec2 create-tags \
    --resources $SECURITY_GROUP_ID \
    --tags "Key=Name,Value=${SECURITY_GROUP_NAME}" \
    --region $REGION

SSH_ALLOW_CIDR="$(curl -s http://checkip.amazonaws.com)/32"
ALLOW_SSH_INGRESS=$(aws ec2 describe-security-groups --filters Name=group-id,Values=$SECURITY_GROUP_ID Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 Name=ip-permission.cidr,Values="$SSH_ALLOW_CIDR" --query "SecurityGroups[*].GroupId" --output text --region $REGION)
if [ -z "$ALLOW_SSH_INGRESS" ]; then
    aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP_ID \
        --protocol tcp \
        --port 22 \
        --cidr "$SSH_ALLOW_CIDR" \
        --region $REGION
fi

EBS_VOLUME_NAME=${EBS_VOLUME_NAME:-dev-vm-data}
VOLUME_ID=$(aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=${EBS_VOLUME_NAME}" \
  --query 'Volumes[0].VolumeId' \
  --output text --region $REGION)
if [[ -z "$VOLUME_ID" || "$VOLUME_ID" = None ]]; then
  VOLUME_ID=$(aws ec2 create-volume \
    --availability-zone $AVAILABILITY_ZONE \
    --size 30 \
    --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$EBS_VOLUME_NAME}]" \
    --query 'VolumeId' \
    --output text --region $REGION)
  aws ec2 wait volume-available --volume-ids $VOLUME_ID --region $REGION
fi

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text --region $REGION)
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == None ]]; then
    INSTANCE_ID=$(aws ec2 run-instances \
                      --image-id $AMI_ID \
                      --instance-type m7i.large \
                      --count 1 \
                      --security-group-ids $SECURITY_GROUP_ID \
                      --subnet-id $SUBNET_ID \
                      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
                      --query 'Instances[0].InstanceId' \
                      --output text --region $REGION)
    aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID --region $REGION
fi
PUBLIC_IP=$(aws ec2 describe-instances \
                --instance-ids $INSTANCE_ID \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text --region $REGION)

ATTACHED_VOLUME=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=status,Values=in-use" "Name=tag:Name,Values=${EBS_VOLUME_NAME}" --query 'Volumes[0].VolumeId' --output text --region $REGION)
if [[ -z "${ATTACHED_VOLUME}" || "${ATTACHED_VOLUME}" = None ]]; then
    aws ec2 attach-volume \
        --volume-id $VOLUME_ID \
        --instance-id $INSTANCE_ID \
        --device /dev/sdf \
        --region $REGION
    aws ec2 wait volume-in-use --volume-ids $VOLUME_ID --region $REGION
fi

ssh -o StrictHostKeyChecking=no $PUBLIC_IP /usr/local/bin/mount-data.sh
echo "ssh $PUBLIC_IP"
