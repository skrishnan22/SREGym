#!/usr/bin/env bash
# Manage the SREGym VM on EC2.
#
#   scripts/harness/vm.sh launch [spot|ondemand]   create the VM (once)
#   scripts/harness/vm.sh start                    start it and refresh ~/.ssh/config
#   scripts/harness/vm.sh stop                     stop it (disk kept, compute billing stops)
#   scripts/harness/vm.sh status                   show state, type and IP
#   scripts/harness/vm.sh allow-my-ip              re-point the SSH rule at your current IP
#
# Terminating is deliberately not here: do it in the console at the end of the exercise.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-sregym}"
NAME=sregym-vm
TYPE="${VM_TYPE:-c7a.2xlarge}"
DISK_GB=100
KEY_NAME=sregym-vm
KEY_FILE="$HOME/.ssh/sregym-vm"
SG_NAME=sregym-ssh
# Canonical's Ubuntu 24.04 amd64 owner; the newest image is looked up at launch.
UBUNTU_OWNER=099720109477
UBUNTU_NAME='ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*'

instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

sg_id() {
  aws ec2 describe-security-groups --group-names "$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text
}

public_ip() {
  aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

write_ssh_config() {
  local ip="$1" config="$HOME/.ssh/config"
  touch "$config"
  # Drop any previous block for this host, then append a fresh one.
  awk -v host="$NAME" '
    $1 == "Host" { skip = ($2 == host) }
    !skip
  ' "$config" > "$config.tmp" && mv "$config.tmp" "$config"
  cat >> "$config" <<EOF
Host $NAME
  HostName $ip
  User ubuntu
  IdentityFile $KEY_FILE
  IdentitiesOnly yes
  ServerAliveInterval 60
EOF
  chmod 600 "$config"
  echo "~/.ssh/config: $NAME -> $ip"
}

cmd_launch() {
  local market="${1:-spot}"
  [[ "$(instance_id)" == "None" ]] || { echo "$NAME already exists: $(instance_id)"; exit 1; }

  local ami
  ami=$(aws ec2 describe-images --owners "$UBUNTU_OWNER" \
    --filters "Name=name,Values=$UBUNTU_NAME" "Name=state,Values=available" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

  local market_args=()
  if [[ "$market" == "spot" ]]; then
    # Persistent + stop-on-interruption so the instance can be stopped and started like on-demand.
    market_args=(--instance-market-options \
      'MarketType=spot,SpotOptions={SpotInstanceType=persistent,InstanceInterruptionBehavior=stop}')
  fi

  local id
  id=$(aws ec2 run-instances \
    --image-id "$ami" --instance-type "$TYPE" --key-name "$KEY_NAME" \
    --security-group-ids "$(sg_id)" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
    "${market_args[@]}" \
    --query 'Instances[0].InstanceId' --output text)

  echo "launched $id ($TYPE, $market, $ami)"
  aws ec2 wait instance-running --instance-ids "$id"
  write_ssh_config "$(public_ip "$id")"
}

cmd_start() {
  local id; id=$(instance_id)
  aws ec2 start-instances --instance-ids "$id" >/dev/null
  aws ec2 wait instance-running --instance-ids "$id"
  write_ssh_config "$(public_ip "$id")"
}

cmd_stop() {
  local id; id=$(instance_id)
  aws ec2 stop-instances --instance-ids "$id" >/dev/null
  echo "stopping $id"
}

cmd_status() {
  local id; id=$(instance_id)
  [[ "$id" == "None" ]] && { echo "no $NAME instance"; return; }
  aws ec2 describe-instances --instance-ids "$id" \
    --query 'Reservations[0].Instances[0].[InstanceId,InstanceType,InstanceLifecycle,State.Name,PublicIpAddress]' \
    --output text
}

cmd_allow_my_ip() {
  local sg ip; sg=$(sg_id); ip=$(curl -s https://checkip.amazonaws.com)
  local old
  old=$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text)
  for cidr in $old; do
    aws ec2 revoke-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$cidr" >/dev/null
  done
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$ip/32" >/dev/null
  echo "SSH allowed from $ip only"
}

case "${1:-}" in
  launch) cmd_launch "${2:-spot}" ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  allow-my-ip) cmd_allow_my_ip ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
