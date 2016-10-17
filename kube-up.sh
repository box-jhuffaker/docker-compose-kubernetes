#!/bin/bash

set -e

this_dir=$(cd -P "$(dirname "$0")" && pwd)

require_command_exists() {
    command -v "$1" >/dev/null 2>&1 || { echo "$1 is required but is not installed. Aborting." >&2; exit 1; }
}

require_command_exists kubectl
require_command_exists docker

docker info > /dev/null
if [ $? != 0 ]; then
    echo "A running Docker engine is required. Is your Docker host up?"
    exit 1
fi

if [[ ! $(docker version --format {{.Server.Version}})  == "1.10.3" ]]; then
    echo "Error: You should be running docker 1.10.3"
    exit 1
fi

echo "Setting up kubectl context"
api_address="localhost"
if command -v docker-machine >/dev/null 2>&1; then
    api_address=$(docker-machine ip)
fi

kubectl config set-cluster local --server="http://$api_address:8080" >/dev/null 2>&1
kubectl config set-context local --cluster=local >/dev/null 2>&1
kubectl config use-context local >/dev/null 2>&1

if kubectl cluster-info &> /dev/null; then
    echo "Kubernetes is already running"
    exit 1
fi

echo "Cleaning up last kubernetes run (may ask for sudo)"
if command -v docker-machine >/dev/null 2>&1; then
    docker-machine ssh $DOCKER_MACHINE_NAME "mount | grep -o 'on /var/lib/kubelet.* type' | cut -c 4- | rev | cut -c 6- | rev | sort -r | xargs --no-run-if-empty sudo umount"
    docker-machine ssh $DOCKER_MACHINE_NAME "sudo rm -Rf /var/lib/kubelet"
    docker-machine ssh $DOCKER_MACHINE_NAME "sudo mkdir -p /var/lib/kubelet"
    docker-machine ssh $DOCKER_MACHINE_NAME "sudo mount --bind /var/lib/kubelet /var/lib/kubelet"
    docker-machine ssh $DOCKER_MACHINE_NAME "sudo mount --make-shared /var/lib/kubelet"
    docker-machine ssh $DOCKER_MACHINE_NAME "sudo mkdir -p /etc/kubernetes/manifests"
    docker-machine scp -r "$this_dir/manifests/" "$DOCKER_MACHINE_NAME:/tmp" 2>&1 > /dev/null
    docker-machine ssh $DOCKER_MACHINE_NAME "sudo cp -r /tmp/manifests/ /etc/kubernetes"
else
    mount | grep -o 'on /var/lib/kubelet.* type' | cut -c 4- | rev | cut -c 6- | rev | sort -r | xargs --no-run-if-empty sudo umount
    sudo rm -Rf /var/lib/kubelet
    sudo mkdir -p /var/lib/kubelet
    sudo mount --bind /var/lib/kubelet /var/lib/kubelet
    sudo mount --make-shared /var/lib/kubelet
    cp -r "$this_dir/manifests/" "$DOCKER_MACHINE_NAME:/etc/kubernetes"
fi

if [[ -f "$HOME/.docker/config.json" ]]; then
    private_repo_creds_mount="--volume=\"$HOME/.docker:/root/.docker\""
else
    echo "Warning: Docker registry credentials not found, private registries disabled."
    private_repo_creds_mount=""
fi

echo "Starting kubelet"
docker run \
    --name=kubelet \
    --volume=/:/rootfs:ro \
    --volume=/sys:/sys:ro \
    --volume=/var/lib/docker/:/var/lib/docker:rw \
    --volume=/var/run:/var/run:rw \
    --volume=/var/lib/kubelet:/var/lib/kubelet:shared \
    --volume=/etc/kubernetes/manifests:/etc/kubernetes/manifests \
    $private_repo_creds_mount \
    --net=host \
    --pid=host \
    --privileged=true \
    -d \
    gcr.io/google_containers/hyperkube-amd64:v1.3.7 \
    /hyperkube kubelet \
        --hostname-override="127.0.0.1" \
        --address="0.0.0.0" \
        --api-servers=http://localhost:8080 \
        --config=/etc/kubernetes/manifests \
        --cluster-dns=10.0.0.10 \
        --cluster-domain=cluster.local \
        --allow-privileged=true --v=2 >/dev/null 2>&1

echo "Waiting for Kubernetes cluster to become available..."
until $(kubectl cluster-info &> /dev/null); do
    sleep 1
done
echo "Kubernetes cluster is up."

