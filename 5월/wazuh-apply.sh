#!/bin/bash
# Wazuh 커스텀 디코더 및 룰 적용 스크립트
# cp 서버(물리서버)에서 실행

echo "=== 디코더 적용 ==="
sudo cp wazuh-falco-decoder.xml /var/ossec/etc/decoders/falco_decoders.xml

echo "=== 룰 적용 ==="
sudo cp wazuh-falco-rules.xml /var/ossec/etc/rules/falco_rules.xml

echo "=== 설정 검증 ==="
sudo /var/ossec/bin/wazuh-analysisd -t

echo "=== Wazuh Manager 재시작 ==="
sudo systemctl restart wazuh-manager

echo "=== logtest로 매칭 확인 ==="
echo "아래 명령어로 실제 Falco 로그 붙여넣어 테스트:"
echo "sudo /var/ossec/bin/wazuh-logtest"
echo ""
echo "=== 알림 로그 실시간 확인 ==="
echo "sudo tail -f /var/ossec/logs/alerts/alerts.log"
