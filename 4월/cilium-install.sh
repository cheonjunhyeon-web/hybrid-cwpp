#!/bin/bash
# Cilium CNI 설치 스크립트
# eBPF 기반 네트워크 플러그인
# kubeadm init 완료 후 실행

# Helm 설치
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Cilium Helm 레포 추가
helm repo add cilium https://helm.cilium.io/
helm repo update

# Cilium 설치
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.1.100 \
  --set k8sServicePort=6443

# 설치 확인
echo "=== Cilium 상태 확인 ==="
kubectl get pods -n kube-system | grep cilium

echo "=== 노드 상태 확인 ==="
kubectl get nodes
