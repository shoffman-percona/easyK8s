#!/bin/bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
cwd=`pwd`
default_region="us-east-2"
default=""

usage () {
        echo "usage: ./easyk8s-aws.sh AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY [region]"
        echo "region is optional, defaults to $default_region"
}

#######################################
# Defines colours for output messages.
#######################################
setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m'
    BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

#######################################
# Prints message to stderr with new line at the end.
#######################################
msg() {
  echo >&2 -e "${1-}"
}

#######################################
# Prints message and exit with code.
# Arguments:
#   message string;
#   exit code.
# Outputs:
#   writes message to stderr.
#######################################
die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

#######################################
# Clean up setup if interrupt.
#######################################
cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
}

#######################################
# Check if MacOS
#######################################
is_darwin() {
   case "$(uname -s)" in
     *darwin* | *Darwin* ) true ;;
     * ) false;;
   esac
}

install_aws_cli () {
echo "[INFO] Installing AWS CLI"
   mkdir aws-cli
   export PATH=$PATH:$cwd/aws-cli
   if is_darwin
     then
	echo "[INFO] MacOS detected"
	exit
	curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "awscliv2.pkg"
	sudo installer -pkg awscliv2.pkg -target /
	rm -f awscliv2.pgk
   else
 	curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip -qq awscliv2.zip
        sudo ./aws/install -i ./aws-cli
	rm -f awscliv2.zip
   fi
}

install_kubectl () {
echo "[INFO] Installing kubectl"
   if is_darwin
     then
     	curl -o ./aws-cli/kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/darwin/amd64/kubectl
	chmod +x ./aws-cli/kubectl
   else
	curl -s -o ./aws-cli/kubectl https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/kubectl
        chmod +x ./aws-cli/kubectl
   fi
}

install_iam_auth () {
echo "[INFO] Installing AWS IAM authenticator"
   if is_darwin
     then
	curl -o ./aws-cli/aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/darwin/amd64/aws-iam-authenticator	
	chmod +x ./aws-cli/aws-iam-authenticator
   else
        curl -s -o ./aws-cli/aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
        chmod +x ./aws-cli/aws-iam-authenticator
   fi
}

install_eksctl () {
echo "[INFO] Installing eksctl"
   if is_darwin
     then
	#need to get eksctl installed for mac
	echo "Mac support not built yet"
	exit
   else
        curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C ./aws-cli/
   fi
}

deploy_eks () {
        echo "[INFO] Deploying EKS with eksctl. It might take some time."
        # default to spot instances not to waste resources
        # problem - it is required to set the zones. Need to implement logic for zone setting based on region
        ./aws-cli/eksctl create cluster --managed --spot --instance-types=m5.xlarge,m4.xlarge,m5.2xlarge --zones=${region}a,${region}b,${region}c --name=pmmDBaaS --nodes=3
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
apiVersion: rbac.authorization.k8s.io/v1
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
apiVersion: rbac.authorization.k8s.io/v1
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
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: service-account-percona-server-dbaas-admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
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

aws_key=${1:-}
if [ -z "$aws_key" ]
        then
                echo "[ERROR] No AWS_ACCESS_KEY_ID set"
		read -p "Enter your AWS Access Key ID: " AWS_ACCESS_KEY_ID
	else 
		AWS_ACCESS_KEY_ID=${1}
fi

aws_secret=${2:-}
if [ -z "$aws_secret" ]
        then
                echo "[ERROR] No AWS_SECRET_ACCESS_KEY set"
		read -p "Enter your AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY
	else
		AWS_SECRET_ACCESS_KEY=${2}
fi

reg=${3:-}
if [ -z "$reg" ]
        then
                echo "[INFO] No region is set, defaulting to $default_region"
                region=$default_region
        else
		echo "[INFO] Region override to $reg"
                region=$reg
fi

export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=$region
export AWS_DEFULT_OUTPUT=json


# run the thing
setup_colors
install_aws_cli
install_kubectl
install_iam_auth
install_eksctl
deploy_eks
apply_k8s_roles
generate_kubeconfig
