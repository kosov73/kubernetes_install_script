#!/bin/bash

hostname=$(uname -n)
host_ip=$(hostname -I | awk '{print $1}')
kube_version="v1.29"

if [ $# -eq 0 ]; then
    echo "Usage: install.sh [option]"
    echo "Options:"
    echo "  - master: Execute code for master"
    echo "  - node: Execute code for node"
    exit 1
fi

setup_kubernetes() 
{
    echo "Disable swap forever"
    sudo swapoff -a
    sed -e '/swap/ s/^#*/#/' -i /etc/fstab

    echo "Forwarding IPv4 and letting iptables see bridged traffic"
    cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    echo "Enable overlay and br_netfilter"
    sudo modprobe overlay
    sudo modprobe br_netfilter

    echo "Tuning sysctl"
    cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    sudo sysctl --system

    echo "Install apt-transport-https, ca-certificates, curl, gnupg, lsb-release"
    sudo apt-get update
    sudo apt-get install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release -y

    echo "Install containerd"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
    sudo mkdir -p /etc/containerd
    sudo bash -c 'containerd config default > /etc/containerd/config.toml'
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl enable containerd
    sudo systemctl restart containerd

    echo "Install kubeadm, kubelet and kubectl"
    curl -fsSL https://pkgs.k8s.io/core:/stable:/$kube_version/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    # This overwrites any existing configuration in /etc/apt/sources.list.d/kubernetes.list
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$kube_version/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl

    sudo systemctl start kubelet
    sudo systemctl enable kubelet
}
    
case $1 in
    "master")
        echo "Kubernetes installation is in progress on node $hostname"
        setup_kubernetes
        kubeadm init --pod-network-cidr=192.168.0.0/16
        sudo mkdir $HOME/.kube/
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
        cd $HOME/
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.5/deploy/static/provider/cloud/deploy.yaml
        wget https://get.helm.sh/helm-v3.12.3-linux-amd64.tar.gz
        sudo tar -zxvf helm-v3.12.3-linux-amd64.tar.gz
        sudo mv linux-amd64/helm /usr/local/bin/helm
        kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec": {"type": "LoadBalancer", "externalIPs":["'$host_ip'"]}}'
        helm repo add rimusz https://charts.rimusz.net
        helm repo update
        helm upgrade --install hostpath-provisioner --namespace kube-system rimusz/hostpath-provisioner
        #kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission
        echo "Create join token"
        kubeadm token create --print-join-command
        ;;
    "node")
        echo "Kubernetes installation is in progress on node $hostname"
        setup_kubernetes
        echo "Installation of kubernetes on the node $hostname is completed"
        ;;
    *)
        echo "Invalid option: $1"
        exit 1
        ;;
esac
