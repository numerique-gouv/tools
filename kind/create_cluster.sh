#!/bin/sh
set -o errexit

CURRENT_DIR=$(pwd)
APPLICATION=${1:-app}
CLUSTERNAME=${2:-suite}

echo "0. Create ca"
# 0. Create ca
mkcert -install
cd /tmp
mkcert "127.0.0.1.nip.io" "*.127.0.0.1.nip.io"
cd $CURRENT_DIR

echo "1. Create registry container unless it already exists"
# 1. Create registry container unless it already exists
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
	docker run \
		-d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" \
		registry:2
fi

echo "2. Create kind cluster with containerd registry config dir enabled"
# 2. Create kind cluster with containerd registry config dir enabled
# TODO: kind will eventually enable this by default and this patch will
# be unnecessary.
#
# See:
# https://github.com/kubernetes-sigs/kind/issues/2875
# https://github.com/containerd/containerd/blob/main/docs/cri/config.md#registry-configuration
# See: https://github.com/containerd/containerd/blob/main/docs/hosts.md
if ! kind get clusters | grep ${CLUSTERNAME}; then
	cat <<EOF | kind create cluster --name ${CLUSTERNAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
  image: kindest/node:v1.27.3
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF
fi

echo "3. Add the registry config to the nodes"
# 3. Add the registry config to the nodes
#
# This is necessary because localhost resolves to loopback addresses that are
# network-namespace local.
# In other words: localhost in the container is not localhost on the host.
#
# We want a consistent name that works from both ends, so we tell containerd to
# alias localhost:${reg_port} to the registry container when pulling images
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes --name ${CLUSTERNAME}); do
	docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
	cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

echo "4. Connect the registry to the cluster network if not already connected"
# 4. Connect the registry to the cluster network if not already connected
# This allows kind to bootstrap the network but ensures they're on the same network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
	docker network connect "kind" "${reg_name}"
fi

echo "5. Document the local registry"
# 5. Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
          lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
          ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
          max_concurrent 1000
        }
        rewrite stop {
          name regex (.*).127.0.0.1.nip.io ingress-nginx-controller.ingress-nginx.svc.cluster.local answer auto
        }
        cache 30
        loop
        reload
        loadbalance
    }
EOF

kubectl -n kube-system rollout restart deployments/coredns

if ! kubectl get ns ingress-nginx; then
	echo "6. Install ingress-nginx"
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx create secret tls mkcert --key /tmp/127.0.0.1.nip.io+1-key.pem --cert /tmp/127.0.0.1.nip.io+1.pem || echo ok
	kubectl -n ingress-nginx patch deployments.apps ingress-nginx-controller --type 'json' -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--default-ssl-certificate=ingress-nginx/mkcert"}]'
fi

if ! kubectl get ns ${APPLICATION}; then
	echo "7. Setup namespace"
	kubectl create ns ${APPLICATION}
	kubectl config set-context --current --namespace=${APPLICATION}
	kubectl -n ${APPLICATION} create secret generic mkcert --from-file=rootCA.pem="$(mkcert -CAROOT)/rootCA.pem" || echo ok
fi

if ! kubectl get configmap certifi -n ${APPLICATION}; then
	echo "8. Inject our custom CA in a configmap for certifi"
	curl https://raw.githubusercontent.com/certifi/python-certifi/refs/heads/master/certifi/cacert.pem -o /tmp/cacert.pem
	cat "$(mkcert -CAROOT)/rootCA.pem" >>/tmp/cacert.pem
	kubectl -n ${APPLICATION} create configmap certifi --from-file=cacert.pem=/tmp/cacert.pem
fi
