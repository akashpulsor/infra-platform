kubectl create ns front-dev
kubectl create ns platform-dev
kubectl create ns tenant-shared
kubectl create ns compliance
kubectl label ns front-dev istio-injection=enabled --overwrite
kubectl label ns platform-dev istio-injection=enabled --overwrite
kubectl label ns tenant-shared istio-injection=enabled --overwrite
