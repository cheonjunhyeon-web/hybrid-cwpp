#!/bin/bash
# Falcosidekick 설정 업그레이드 스크립트
# Wazuh(Syslog)와 Talon 두 곳으로 이벤트 동시 전송하도록 설정
#
# Talon ClusterIP 확인 후 실행:
# kubectl get svc -n falco-talon

TALON_IP="10.99.101.115"
TALON_PORT="2803"

helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --reuse-values \
  --set falcosidekick.config.talon.address=http://${TALON_IP}:${TALON_PORT} \
  --set falcosidekick.config.talon.minimumpriority=warning

echo "=== Falcosidekick 출력 확인 ==="
echo "활성화된 출력: Syslog + Talon"
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick | tail -5
