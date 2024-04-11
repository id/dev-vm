#!/usr/bin/env bash

set -euo pipefail

INSTANCE_TYPE="t3.small"
REGION="eu-north-1"
SSH_PUBLIC_KEY="~/.ssh/id_ed25519.pub"
TMP_SSH_KEY_NAME="temp-ssh-key-$(date +%s)"
BASE_AMI_NAME_FILTER="debian-12-amd64*"
BASE_AMI_DISTRO="debian"
BASE_AMI_OWNER="amazon"
AMI_NAME="dev-vm-$(date +%s)"
AMI_INSTALL_SCRIPT="ami-install-${BASE_AMI_DISTRO}.sh"
SSH_USER=admin
DEV_USER=$(whoami)
START_AT=init

while [ $# -gt 0 ]; do
  case "$1" in
    --instance-type)
      INSTANCE_TYPE="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --ssh-public-key)
      SSH_PUBLIC_KEY="$2"
      shift 2
      ;;
    --base-ami-name-filter)
      BASE_AMI_NAME_FILTER="$2"
      shift 2
      ;;
    --base-ami-owner)
      BASE_AMI_OWNER="$2"
      shift 2
      ;;
    --ami-name)
      AMI_NAME="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --dev-user)
      DEV_USER="$2"
      shift 2
      ;;
    --start-at)
      START_AT="$2"
      shift 2
      ;;
    --ami-install-script)
      AMI_INSTALL_SCRIPT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

echo "Using the following parameters:"
echo "  Instance type: $INSTANCE_TYPE"
echo "  Region: $REGION"
echo "  SSH public key: $SSH_PUBLIC_KEY"
echo "  Base AMI name filter: $BASE_AMI_NAME_FILTER"
echo "  Base AMI distro: $BASE_AMI_DISTRO"
echo "  Base AMI owner: $BASE_AMI_OWNER"
echo "  AMI name: $AMI_NAME"
echo "  AMI install script: $AMI_INSTALL_SCRIPT"
echo "  SSH user: $SSH_USER"
echo "  Dev user: $DEV_USER"
echo

if [ ! -f .resources ]; then
    echo "REGION=$REGION" > .resources
    echo "INSTANCE_TYPE=$INSTANCE_TYPE" >> .resources
    echo "SSH_PUBLIC_KEY=$SSH_PUBLIC_KEY" >> .resources
    echo "BASE_AMI_NAME_FILTER='$BASE_AMI_NAME_FILTER'" >> .resources
    echo "BASE_AMI_DISTRO=$BASE_AMI_DISTRO" >> .resources
    echo "BASE_AMI_OWNER=$BASE_AMI_OWNER" >> .resources
    echo "AMI_NAME=$AMI_NAME" >> .resources
    echo "AMI_INSTALL_SCRIPT=$AMI_INSTALL_SCRIPT" >> .resources
    echo "SSH_USER=$SSH_USER" >> .resources
    echo "DEV_USER=$DEV_USER" >> .resources
fi

init() {
    . .resources
    printf "init"
    VPC_ID=${VPC_ID:-$(aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`true`].[VpcId]' --output text --region $REGION)}
    printf "."
    echo "VPC_ID=$VPC_ID" >> .resources
    printf "."
    BASE_AMI_ID=${BASE_AMI_ID:-$(aws ec2 describe-images --owners $BASE_AMI_OWNER --filters "Name=name,Values=$BASE_AMI_NAME_FILTER" --query 'Images|sort_by(@,&CreationDate)[-1].ImageId' --output text --region $REGION)}
    printf "."
    echo "BASE_AMI_ID=$BASE_AMI_ID" >> .resources
    echo "done"
}

create_security_group() {
    . .resources
    printf "create_security_group"
    SECURITY_GROUP_ID=$(aws ec2 create-security-group --group-name temp-sg-for-ami --description "Temporary security group" --vpc-id $VPC_ID --query 'GroupId' --output text --region $REGION)
    printf "."
    echo "SECURITY_GROUP_ID=$SECURITY_GROUP_ID" >> .resources
    printf "."
    aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr $(curl -s http://checkip.amazonaws.com)/32 --region $REGION > /dev/null
    echo "done"
}

create_key_pair() {
    . .resources
    printf "create_key_pair"
    if aws ec2 describe-key-pairs --key-names $TMP_SSH_KEY_NAME --region $REGION &>/dev/null; then
        printf "."
        if [ -f $TMP_SSH_KEY_NAME.pem ]; then
            echo "done"
            return
        else
            aws ec2 delete-key-pair --key-name $TMP_SSH_KEY_NAME --region $REGION
            printf "."
        fi
    fi
    printf "."
    aws ec2 create-key-pair \
        --region $REGION \
        --key-name $TMP_SSH_KEY_NAME \
        --key-type ed25519 \
        --key-format pem \
        --query "KeyMaterial" \
        --output text > $TMP_SSH_KEY_NAME.pem
    printf "."
    echo "TMP_SSH_KEY_NAME=$TMP_SSH_KEY_NAME" >> .resources
    printf "."
    chmod 400 $TMP_SSH_KEY_NAME.pem
    echo "done"
}

run_instances() {
    . .resources
    printf "run_instances"
    INSTANCE_ID=$(aws ec2 run-instances --image-id $BASE_AMI_ID --count 1 --instance-type $INSTANCE_TYPE --key-name $TMP_SSH_KEY_NAME --security-group-ids $SECURITY_GROUP_ID --query 'Instances[0].InstanceId' --output text --region $REGION)
    printf "."
    echo "INSTANCE_ID=$INSTANCE_ID" >> .resources
    printf "."
    aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION
    printf "."
    INSTANCE_PUBLIC_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $REGION)
    printf "."
    echo "INSTANCE_PUBLIC_IP=$INSTANCE_PUBLIC_IP" >> .resources
    printf "."
    while ! ssh -i ${TMP_SSH_KEY_NAME}.pem -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_PUBLIC_IP} true 2>/dev/null; do
        sleep 5
        printf "."
    done
    echo "done"
}

install() {
    . .resources
    printf "install"
    cat ${SSH_PUBLIC_KEY} | ssh -o StrictHostKeyChecking=no -i ${TMP_SSH_KEY_NAME}.pem ${SSH_USER}@${INSTANCE_PUBLIC_IP} -T "cat >> ~/.ssh/authorized_keys"
    printf "."
    chmod +x ${AMI_INSTALL_SCRIPT}
    printf "."
    ssh -i ${TMP_SSH_KEY_NAME}.pem -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_PUBLIC_IP} 'bash -s' < ${AMI_INSTALL_SCRIPT} ${DEV_USER}
    echo "done"
}

create_image() {
    . .resources
    printf "create_image"
    AMI_ID=$(aws ec2 create-image --instance-id $INSTANCE_ID --name "${AMI_NAME}" --query 'ImageId' --output text --region $REGION)
    printf "."
    echo "AMI_ID=$AMI_ID" >> .resources
    printf "."
    aws ec2 wait image-available --image-ids $AMI_ID --region $REGION
    echo "done"
    echo "AMI_ID=$AMI_ID"
}

cleanup() {
    . .resources
    printf "cleanup"
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION > /dev/null
    printf "."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION > /dev/null
    printf "."
    aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --region $REGION > /dev/null
    printf "."
    aws ec2 delete-key-pair --key-name $TMP_SSH_KEY_NAME --region $REGION > /dev/null
    printf "."
    rm -f $TMP_SSH_KEY_NAME.pem
    printf "."
    rm -f .resources
    echo "done"
}

declare -a STEPS=(init create_security_group create_key_pair run_instances install create_image cleanup)
start_executing=0
for STEP in "${STEPS[@]}"; do
    if [ "$STEP" == "$START_AT" ]; then
        start_executing=1
    fi
    if [ $start_executing = 1 ]; then
        $STEP
    fi
done
