# K3s on EC2 with IAM Roles Anywhere

Triển khai K3s trên Amazon EC2 bằng certificate X.509 từ máy quản trị. Máy quản trị không dùng access key dài hạn; AWS CLI lấy credential tạm thời qua IAM Roles Anywhere rồi dùng Systems Manager (SSM) để điều khiển EC2.

## Kiến trúc

```text
Máy quản trị + certificate
        |
        v
IAM Roles Anywhere
        |
        v
K3sProvisionerPolicy
        |
        +--> EC2 RunInstances
        +--> SSM SendCommand
                    |
                    v
             EC2 + K3sNodeRole
                    |
                    v
                 K3s cluster
```

`K3sProvisionerPolicy` chỉ dùng cho máy quản trị. EC2 không chứa private key; EC2 dùng `K3sNodeRole` để đăng ký SSM.

## Thành phần

- `k3s-controlplane.sh`: cài K3s server trên control plane.
- `k3s-node.sh`: cài K3s agent khi chạy trực tiếp trên EC2.
- `provision-worker.sh`: tạo worker EC2 và cài agent qua Roles Anywhere + SSM.

## Điều kiện

- AWS Region: `us-east-2`.
- AWS CLI, `jq`, `aws_signing_helper` trên máy quản trị.
- VPC/subnet có internet hoặc VPC endpoints cho EC2, SSM và S3.
- Security group cho K3s: TCP `6443`, UDP `8472`, TCP `10250` giữa các node; DNS TCP/UDP `53`; egress HTTPS `443`.
- Instance profile `K3sNodeRole` gắn vào mọi EC2 node.
- SSM Agent hoạt động và `K3sNodeRole` có `AmazonSSMManagedInstanceCore`.

## 1. Tạo Roles Anywhere

Trên AWS Console, tạo CA hợp lệ (`CA:TRUE`, `keyCertSign,cRLSign`), trust anchor, IAM role `K3sProvisionerPolicy`, rồi profile `k3s-provisioner-profile`.

Quyền quản trị cần có:

```text
ec2:RunInstances
ec2:CreateTags
ec2:Describe*
ec2:ModifyInstanceAttribute
ssm:DescribeInstanceInformation
ssm:SendCommand
ssm:GetCommandInvocation
ssm:ListCommandInvocations
iam:PassRole (chỉ K3sNodeRole)
```

Giới hạn `iam:PassRole` bằng role ARN `arn:aws:iam::<ACCOUNT_ID>:role/K3sNodeRole` và điều kiện `iam:PassedToService = ec2.amazonaws.com`.

Không commit `*.key`, `*.crt`, private-key config hoặc K3s node-token.

## 2. Cấu hình AWS CLI

Tạo profile dùng `credential_process`:

```ini
[profile k3s-rolesanywhere]
region = us-east-2
credential_process = /path/to/aws_signing_helper credential-process \
  --certificate /path/to/deployer.crt \
  --private-key /path/to/deployer.key \
  --trust-anchor-arn arn:aws:rolesanywhere:us-east-2:<ACCOUNT_ID>:trust-anchor/<ID> \
  --profile-arn arn:aws:rolesanywhere:us-east-2:<ACCOUNT_ID>:profile/<ID> \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/K3sProvisionerPolicy
```

Kiểm tra:

```bash
AWS_PROFILE=k3s-rolesanywhere aws sts get-caller-identity
```

ARN phải có dạng `assumed-role/K3sProvisionerPolicy/...`.

## 3. Cài control plane

Trên EC2 control plane:

```bash
sudo ./k3s-controlplane.sh
sudo /usr/local/bin/k3s kubectl get nodes -o wide
```

Không commit K3s token vào repository.

## 4. Tạo worker tự động

Kiểm tra hoặc ghi đè các biến:

```bash
export AWS_PROFILE=k3s-rolesanywhere
export AWS_DEFAULT_REGION=us-east-2
export AMI_ID=ami-xxxxxxxxxxxxxxxxx
export SUBNET_ID=subnet-xxxxxxxxxxxxxxxxx
export SECURITY_GROUP_ID=sg-xxxxxxxxxxxxxxxxx
export INSTANCE_PROFILE=K3sNodeRole
export CONTROL_INSTANCE_ID=i-xxxxxxxxxxxxxxxxx
export NODE_NAME=k3s-worker-2
export INSTANCE_TYPE=t3.small
```

Chạy:

```bash
./provision-worker.sh
```

Script tạo EC2, gắn instance profile, tắt source/destination check, chờ SSM, lấy token từ control plane qua SSM, cài `k3s-agent`, rồi chờ node `Ready`.

## 5. Kiểm tra

```bash
sudo /usr/local/bin/k3s kubectl get nodes -o wide
sudo /usr/local/bin/k3s kubectl get pods -A
```

Hoặc gửi lệnh qua SSM:

```bash
AWS_PROFILE=k3s-rolesanywhere aws ssm send-command \
  --instance-ids "$CONTROL_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["/usr/local/bin/k3s kubectl get nodes -o wide"]' \
  --query Command.CommandId --output text
```

Mọi node cần có trạng thái `Ready`.

## Bảo mật và vận hành

- Certificate/private key chỉ nằm trên máy quản trị hoặc CI được bảo vệ.
- Xoay vòng certificate trước hạn; credential Roles Anywhere là tạm thời.
- Không mở cổng K3s ra toàn internet; giới hạn CIDR hoặc security-group reference.
- Giữ `iam:PassRole` chỉ cho `K3sNodeRole`.
- Theo dõi CloudTrail/CloudWatch cho `RunInstances`, `SendCommand` và Roles Anywhere.
- Xóa EC2 thử nghiệm khi không dùng để tránh phí.

## Giới hạn hiện tại

`provision-worker.sh` có giá trị mặc định theo môi trường `us-east-2`. Khi đổi VPC, subnet, AMI hoặc control plane, truyền lại các biến môi trường tương ứng.
