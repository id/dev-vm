#!/usr/bin/env bash

set -euo pipefail

INSTANCE_NAME=${1:-dev-vm}
REGION=${REGION:-eu-north-1}
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
                  --output text --query 'Reservations[*].Instances[*].InstanceId' --region $REGION)

if [ -z "$INSTANCE_ID" ]; then
    echo "Instance not found"
    exit 1
fi

aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
