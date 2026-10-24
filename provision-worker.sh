#!/usr/bin/env bash
set -Eeuo pipefail

export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-2}
export AWS_PROFILE=${AWS_PROFILE:-k3s-rolesanywhere}

: "${AMI_ID:=ami-053ef5d7ebe355f4a}"
: "${SUBNET_ID:=subnet-05a56effcb5475746}"
: "${SECURITY_GROUP_ID:=sg-036045898ed2b11f1}"
: "${INSTANCE_PROFILE:=K3sNodeRole}"
: "${CONTROL_INSTANCE_ID:=i-0fd6dbd131d1e30a8}"
: "${NODE_NAME:=k3s-worker-$(date +%s)}"
: "${INSTANCE_TYPE:=t3.small}"

command -v aws >/dev/null || { echo "aws CLI is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

echo "Creating ${NODE_NAME}..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NODE_NAME}]" \
  --count 1 --query 'Instances[0].InstanceId' --output text)

cleanup() {
  if [[ ${KEEP_ON_ERROR:-0} != 1 && -n ${INSTANCE_ID:-} ]]; then
    echo "Failure; instance left running: $INSTANCE_ID" >&2
  fi
}
trap cleanup EXIT

aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --no-source-dest-check

for _ in $(seq 1 30); do
  state=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)
  [[ $state == running ]] && break
  sleep 5
done

for _ in $(seq 1 30); do
  ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' --output text)
  [[ $ping == Online ]] && break
  sleep 5
done
[[ ${ping:-} == Online ]] || { echo "SSM did not become Online" >&2; exit 1; }

token_command=$(aws ssm send-command --instance-ids "$CONTROL_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cat /var/lib/rancher/k3s/server/node-token"]' \
  --query Command.CommandId --output text)
for _ in $(seq 1 20); do
  status=$(aws ssm get-command-invocation --command-id "$token_command" \
    --instance-id "$CONTROL_INSTANCE_ID" --query Status --output text)
  [[ $status == Success ]] && break
  sleep 2
done
token=$(aws ssm get-command-invocation --command-id "$token_command" \
  --instance-id "$CONTROL_INSTANCE_ID" --query StandardOutputContent --output text | tr -d '\r\n')
[[ -n $token ]] || { echo "Could not read K3s token" >&2; exit 1; }

printf -v install_cmd 'K3S_URL=https://172.31.11.110:6443 K3S_TOKEN=%q INSTALL_K3S_EXEC=%q sh /tmp/k3s-install.sh' "$token" "agent --node-name $NODE_NAME"
commands=$(jq -n --arg install "$install_cmd" '{commands:["set -Eeuo pipefail", "dnf install -y iptables iproute-tc socat conntrack-tools || true", "modprobe overlay 2>/dev/null || true", "modprobe br_netfilter 2>/dev/null || true", "cat >/etc/sysctl.d/99-k3s.conf <<\"EOF\"\nnet.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\nEOF\nsysctl --system >/dev/null", "curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh", "chmod 700 /tmp/k3s-install.sh", $install, "systemctl enable --now k3s-agent", "systemctl is-active k3s-agent"]}')
install_command=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --parameters "$commands" \
  --query Command.CommandId --output text)
for _ in $(seq 1 60); do
  status=$(aws ssm get-command-invocation --command-id "$install_command" \
    --instance-id "$INSTANCE_ID" --query Status --output text)
  case $status in Success) break;; Failed|Cancelled|TimedOut) aws ssm get-command-invocation --command-id "$install_command" --instance-id "$INSTANCE_ID" --query '[Status,StandardErrorContent]' --output text; exit 1;; esac
  sleep 5
done

for _ in $(seq 1 30); do
  ready=$(aws ssm send-command --instance-ids "$CONTROL_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"/usr/local/bin/k3s kubectl get node '$NODE_NAME' -o jsonpath='{.status.conditions[?(@.type==\\\"Ready\\\")].status}'\"]" \
    --query Command.CommandId --output text)
  sleep 3
  result=$(aws ssm get-command-invocation --command-id "$ready" --instance-id "$CONTROL_INSTANCE_ID" --query StandardOutputContent --output text 2>/dev/null || true)
  [[ $result == True* ]] && break
  sleep 2
done

echo "Worker ready: $INSTANCE_ID ($NODE_NAME)"
