#!/bin/bash
# VPN 라우팅 복구 스크립트
# Cilium(10.0.0~2.x)과 AWS VPC(10.0.0.0/16) CIDR 충돌 해결
# 재부팅 후 또는 라우팅 문제 발생 시 실행

echo "=== VPN 라우팅 복구 시작 ==="

# 1. 충돌 라우트 제거 (AWS 10.x를 로컬로 오인하는 경우)
echo "[1/4] 충돌 라우트 제거"
sudo ip route del 10.0.0.0/16 dev eno1 2>/dev/null || true

# 2. Cilium 로컬 대역 유지 (10.0.0~2.x)
echo "[2/4] Cilium 로컬 라우트 확인"
sudo ip route add 10.0.0.0/24 via 10.0.1.199 dev cilium_host 2>/dev/null || true
sudo ip route add 10.0.1.0/24 via 10.0.1.199 dev cilium_host 2>/dev/null || true
sudo ip route add 10.0.2.0/24 via 10.0.1.199 dev cilium_host 2>/dev/null || true

# 3. AWS VPC 대역 라우트 추가 (Cilium 대역 제외, 10.0.3~255)
echo "[3/4] AWS VPC 라우트 추가"
for i in $(seq 3 255); do
    sudo ip route add 10.0.${i}.0/24 via 211.170.162.1 dev eno1 2>/dev/null || true
done

# RDS 서브넷 명시적 추가
sudo ip route add 10.0.21.0/24 via 211.170.162.1 dev eno1 2>/dev/null || true

# 4. IPSec 재시작
echo "[4/4] IPSec 재시작"
sudo ipsec restart
sleep 3
sudo ipsec statusall | grep -E "ESTABLISHED|CONNECTING"

echo "=== 라우팅 복구 완료 ==="
echo "검증: ip route get 10.0.21.254"
ip route get 10.0.21.254
