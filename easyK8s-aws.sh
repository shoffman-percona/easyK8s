#!/bin/bash

cwd=`pwd`

usage () {
        echo "usage: ./easyk8s-aws.sh AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY [region]"
        echo "region is optional, defaults to us-east-2"
}

install_aws_cli () {
        echo "[INFO] Installing AWS CLI"
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        mkdir aws-cli
        sudo ./aws/install -i ./aws-cli
}

install_kubectl () {
        echo "[INFO] Installing kubectl"
        curl -o ./aws-cli/kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/kubectl
        chmod +x ./aws-cli/kubectl
        export PATH=$PATH:$cwd/aws-cli
}

install_iam_auth () {
        echo "[INFO] Installing AWS IAM authenticator"
        curl -o ./aws-cli/aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
        chmod +x ./aws-cli/aws-iam-authenticator
        cp ./aws-cli/aws-iam-authenticator /usr/local/sbin/
}

install_eksctl () {
        echo "[INFO] Installing eksctl"
        curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C ./aws-cli/
}

deploy_eks () {
        echo "[INFO] Deploying EKS with eksctl. It might take some time."
        # default to spot instances not to waste resources
        # problem - it is required to set the zones. Need to implement logic for zone setting based on region
        eksctl create cluster --managed --spot --instance-types=m5.xlarge,m4.xlarge,m5.2xlarge --zones=us-east-2a,us-east-2b,us-east-2c --name=pmmDBaaS
}

apply_k8s_roles () {
        echo "[INFO] Applying service accounts and roles for DBaaS on Kubernetes cluster"
        cat <<EOF | kubectl apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: percona-dbaas-cluster-operator
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: service-account-percona-server-dbaas-xtradb-operator
subjects:
- kind: ServiceAccount
  name: percona-dbaas-cluster-operator
roleRef:
  kind: Role
  name: percona-xtradb-cluster-operator
  apiGroup: rbac.authorization.k8s.io
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: service-account-percona-server-dbaas-psmdb-operator
subjects:
- kind: ServiceAccount
  name: percona-dbaas-cluster-operator
roleRef:
  kind: Role
  name: percona-server-mongodb-operator
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: service-account-percona-server-dbaas-admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: service-account-percona-server-dbaas-operator-admin
subjects:
- kind: ServiceAccount
  name: percona-dbaas-cluster-operator
  namespace: default
roleRef:
  kind: ClusterRole
  name: service-account-percona-server-dbaas-admin
  apiGroup: rbac.authorization.k8s.io
EOF
}

generate_kubeconfig () {

#       name=`kubectl get serviceAccounts percona-dbaas-cluster-operator -o json | jq  -r '.secrets[].name'`
#       certificate=`kubectl get secret $name -o json | jq -r  '.data."ca.crt"'`
#       token=`kubectl get secret $name -o json | jq -r  '.data.token' | base64 -d`
        # avoid jq
        name=`kubectl get serviceAccounts percona-dbaas-cluster-operator -o yaml | awk '$0~/^\-/ {print $3}'`
        certificate=`kubectl get secret $name -o yaml | awk '$0~/ca\.crt:/ {print $2}'`
        token=`kubectl get secret $name -o yaml | awk '$0~/token:/ {print $2}' | base64 --decode`
        server=`kubectl cluster-info | grep 'Kubernetes control plane' | cut -d ' ' -f 7`

echo "
=====================================================================
Copy kubeconfig below and paste it into corresponding section in PMM:
=====================================================================
"

echo "#####BEGIN KUBECONFIG#####"
echo "apiVersion: v1
kind: Config
users:
- name: percona-dbaas-cluster-operator
  user:
    token: $token
clusters:
- cluster:
    certificate-authority-data: $certificate
    server: $server
  name: self-hosted-cluster
contexts:
- context:
    cluster: self-hosted-cluster
    user: percona-dbaas-cluster-operator
  name: svcs-acct-context
current-context: svcs-acct-context"
echo "#####END KUBECONFIG#####"

}

if [ -z $1 ]
        then
                echo "[ERROR] No AWS_ACCESS_KEY_ID set"
                usage
                exit 1;
fi

if [ -z $2 ]
        then
                echo "[ERROR] No AWS_SECRET_ACCESS_KEY set"
                usage
                exit 1;
fi

if [ -z $3 ]
        then
                echo "[INFO] No region is set, defaulting to us-east-2"
                region="us-east-2"
        else
                region=${3}
fi

export AWS_ACCESS_KEY_ID=${1}
export AWS_SECRET_ACCESS_KEY=${2}
export AWS_DEFAULT_REGION=$region
export AWS_DEFULT_OUTPUT=json


# run the thing
install_aws_cli
install_kubectl
install_iam_auth
install_eksctl
deploy_eks
apply_k8s_roles
generate_kubeconfig
