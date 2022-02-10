#!/bin/bash

cwd=`pwd`

#aws cli setup
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
mkdir aws-cli
sudo ./aws/install -i ./aws-cli

#kubectl install
curl -o ./aws-cli/kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/kubectl
chmod +x ./aws-cli/kubectl
export PATH=$PATH:$cwd/aws-cli

#iam authenticator
curl -o ./aws-cli/aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-cli/aws-iam-authenticator

#eksctl install
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C ./aws-cli/

# Prompt user that credentials must be for an administrative user OR needs to have EKS API permissions added

# get aws Access Key ID
# get aws SEcret Access Key
accessKey=
secretAccessKey=
region="us-east-2"
clusterName="pmmDBaaS"
outputFormat="json"
export AWS_ACCESS_KEY_ID=$accessKey
export AWS_SECRET_ACCESS_KEY=$secreatAccessKey
export AWS_DEFAULT_REGION=$region
export AWS_DEFULT_OUTPUT=json

#create VPC
aws cloudformation create-stack \
  --region $region \
  --stack-name $clusterName-vpc-stack \
  --template-url https://amazon-eks.s3.us-west-2.amazonaws.com/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml

#create cluster IAM role
cat << EOF > ./aws-cli/cluster-role-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
aws iam create-role \
  --role-name $clusterName-EKSClusterRole \
  --assume-role-policy-document file://"./aws-cli/cluster-role-trust-policy.json"

aws iam attach-role-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
  --role-name $clusterName-EKSClusterRole


#unclear if the aws cli is a better option than eksctl...seems eksctl command are easier to get it up and running so below may be a waste and instead try to use https://docs.aws.amazon.com/eks/latest/userguide/getting-started-eksctl.html for a basic cluster to point PMM to. 


#create EKS cluster  

### this needs cleanup to associate the role and vpc stack above still...
aws eks create-cluster \
   --region $region \
   --name $clusterName \
   --kubernetes-version 1.21 \
   --role-arn arn:aws:iam::111122223333:role/eks-service-role-AWSServiceRoleForAmazonEKS-EXAMPLEBKZRQR \
   --resources-vpc-config subnetIds=subnet-a9189fe2,subnet-50432629,securityGroupIds=sg-f5c54184


#check for cluster "ACTIVE"
aws eks describe-cluster \
    --region $region \
    --name $clusterName \
    --query "cluster.status"

#create kubeconfig
mkdir ./aws-cli/.kube
kubeconfig="./aws-cli/.kube/config-$clusterName"
export KUBECONFIG=$KUBECONFIG:$cwd/$kubeconfig
endpoint=`aws eks describe-cluster --region $region --name $clusterName --query "cluster.endpoint" --output text`
certificateData=`aws eks describe-cluster --region $region --name $clusterName --query "cluster.certificateAuthority.data" --output text`

cat << EOF > $kubeconfig
apiVersion: v1
clusters:
- cluster:
    server: $endpoint
    certificate-authority-data: $certificateData
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws
      args:
        - "eks"
        - "get-token"
        - "--cluster-name"
        - "$clusterName"
        # - "--role-arn"
        # - "role-arn"
      # env:
        # - name: AWS_PROFILE
        #   value: "aws-profile"
EOF


aws eks update-kubeconfig --kubeconfig=#kubeconfig --region $region --name $clusterName


