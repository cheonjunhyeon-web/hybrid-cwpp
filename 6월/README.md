# Month 04 — Grafana 모니터링 및 전체 파이프라인 검증 (2026.06)

## 작업 개요

5월에 완성한 보안 탐지 및 자동 대응 파이프라인 위에
Grafana 통합 모니터링 대시보드를 구성하고 전체 시스템을 최종 검증했다.

HTTP 공격 로그(nginx)와 Falco 런타임 탐지 이벤트를 단일 대시보드에서 통합 확인할 수 있도록 구성했으며,
공격자 IP / 공격 유형 / 실행 명령 / 위험도를 실시간으로 분류하고 시각화했다.

<br>

## 전체 시스템 아키텍처 최종 구성

<pre>
외부 공격자
    │
    ▼
AWS ALB → EKS Worker Node (delta-lab Pod)
    │
    ├── nginx 로그 ──────────────────────────→ Grafana (HTTP 공격 로그 패널)
    │
    └── Falco 런타임 탐지 (proc.tty != 0)
            │
            ▼
        Falcosidekick
            ├── Syslog (UDP 5140) ──→ Wazuh SIEM (Rule 100620)
            ├── Kafka ──────────────→ falco-events 토픽
            └── HTTP POST ─────────→ Falco Talon → Pod 자동 삭제
                                          │
                                          ▼
                                    Grafana (Falco 탐지 패널)
</pre>

<br>

## 이달 작업 상세

### 1. Grafana 대시보드 구성

Wazuh Indexer(OpenSearch)와 nginx 로그를 데이터 소스로 연결하여
보안 이벤트를 실시간으로 시각화하는 통합 대시보드를 구성했다.

**대시보드 패널 구성**

| 패널 | 데이터 소스 | 내용 |
|---|---|---|
| Falco 탐지 수 (선택 구간) | Wazuh Indexer | Rule 100620 탐지 건수 |
| 공격자 IP 수 (웹 로그) | nginx 로그 | 고유 공격자 IP 카운트 |
| 공격 이벤트 시계열 (1분 단위) | 복합 | Falco 탐지 + 웹 접근 추이 |
| HTTP 공격 로그 | nginx 로그 | 시간 / 방법 / 공격자 IP / 상태 / 요청 경로 |
| Falco 컨테이너 공격 탐지 | Wazuh Indexer | 시간 / 노드 / 대상 파일 / 파드 / 실행 명령 / 위험도 / 탐지 룰 |

**탐지 안내 설정**

```
Falco: /v2/lab/exec (RCE) 만 탐지 — SQLi /secret 은 Falco 없음
공격자 IP: /secret · /exec 모두 nginx 로그
시간: Last 15m | 새로고침: 5s | 공격 후 10초 대기
```

---

### 2. Grafana 설치 (Kubernetes)

Wazuh와 동일한 물리서버 Kubernetes 클러스터에 Grafana를 배포했다.
Nginx Ingress를 통해 외부에서 접근 가능하도록 구성했다.

```bash
# Grafana Helm 레포 추가
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Grafana 설치
helm install grafana grafana/grafana \
  --namespace monitoring \
  --create-namespace \
  --set persistence.enabled=true \
  --set persistence.size=5Gi \
  --set service.type=ClusterIP

# 서비스 확인
kubectl get svc -n monitoring | grep grafana

# 초기 admin 비밀번호 확인
kubectl get secret --namespace monitoring grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode
```

---

### 3. 데이터 소스 연결

**Wazuh Indexer (OpenSearch)**

Falco 탐지 이벤트 및 보안 알림 데이터를 가져오기 위해
Wazuh Indexer를 OpenSearch 데이터 소스로 연결했다.

```
URL: http://<wazuh-indexer-ip>:9200
Index: wazuh-alerts-*
Time field: @timestamp
```

**nginx 로그**

HTTP 공격 로그 수집을 위해 nginx 액세스 로그를 Loki 또는 직접 파싱하여 연결했다.

```
공격자 IP: /secret · /exec 경로 모두 수집
필터: status 200 / 400 / 공격 패턴 경로
```

---

### 4. 최종 파이프라인 검증

**검증 시나리오**

브라우저에서 RCE 공격 수행:

```
http://<EKS-ALB>/v2/lab/exec?cmd=cat%20/etc/passwd
```

**검증 결과 (2026.06.08 ~ 2026.06.10)**

| 항목 | 결과 |
|---|---|
| Falco 탐지 이벤트 수 | 38건 |
| 공격자 IP 수 (웹 로그) | 11개 |
| 탐지 갱신 주기 | 5초 |
| 공격 후 대기 시간 | 10초 |

**단계별 검증**

| 단계 | 구성요소 | 결과 |
|---|---|---|
| 1. 공격 수행 | 브라우저 RCE | /etc/passwd 노출 (의도된 취약점) |
| 2. 런타임 탐지 | Falco (worker1) | Warning 이벤트 생성 |
| 3. 이벤트 라우팅 | Falcosidekick | Syslog + Kafka + Talon 동시 전송 |
| 4. SIEM 수집 | Wazuh Manager | Rule 100620 매칭, Alert 생성 |
| 5. 대시보드 표시 | Grafana | 실시간 알림 표시 |
| 6. 자동 대응 | Falco Talon | delta-lab Pod 자동 삭제 |
| 7. 서비스 복원 | Kubernetes | 새 Pod 자동 재생성 |

**Falco 탐지 상세 (Grafana 대시보드)**

| 시간 | 노드 | 대상 파일 | 실행 명령 | 위험도 | 탐지 룰 |
|---|---|---|---|---|---|
| 2026-06-09 10:33:51 | worker1 | /etc/passwd | whoami | Warning | Delta Lab Sensitive File Read |
| 2026-06-09 10:33:51 | worker1 | - | sh -c whoami | Warning | Delta Lab Shell Spawned |
| 2026-06-09 10:33:50 | worker1 | - | sh -c whoami | Warning | Delta Lab Shell Spawned |

---

### 5. 대시보드 스크린샷

<p align="center">
<img width="1370" height="508" alt="스크린샷 2026-06-10 오전 10 52 16" src="https://github.com/user-attachments/assets/4ab3eabd-5f08-4682-8c38-cc557d03087a" />

  <br>
  <em>Grafana 통합 보안 이벤트 모니터링 대시보드 — Falco 탐지 38건 / 공격자 IP 11개</em>
</p>

<p align="center">
   <img width="1355" height="650" alt="스크린샷 2026-06-10 오전 10 52 29" src="https://github.com/user-attachments/assets/250d73c0-123d-4022-b5d8-968830a057c5" />
  <br>
  <em>HTTP 공격 로그 및 Falco 컨테이너 공격 탐지 상세</em>
</p>

<br>

## 전체 프로젝트 성과 요약

**구현 완료 항목**

| 항목 | 상태 |
|---|---|
| AWS VPC / EKS 클러스터 구성 | 완료 |
| 물리서버 3대 Kubernetes HA 구성 | 완료 |
| Kafka 클러스터 분산 배치 (3 Broker) | 완료 |
| Site-to-Site VPN 연결 | 완료 |
| Falco 런타임 탐지 | 완료 |
| Wazuh SIEM 커스텀 디코더/룰 | 완료 |
| Falco Talon 자동 대응 | 완료 |
| Grafana 통합 대시보드 | 완료 |

**기술적 성과**

- AWS EKS와 온프레미스 Kubernetes를 VPN으로 연결한 하이브리드 보안 아키텍처 구현
- Falcosidekick → Syslog 메시지 파싱 문제 해결 (커스텀 디코더 직접 작성)
- Talon 무한루프 문제 해결 (proc.tty 조건 + deduplication 조합)
- Cilium CIDR 충돌 / IKEv1 협상 / CGW IP 불일치 등 VPN 트러블슈팅 직접 해결
- 탐지 → 분석 → 자동 대응 → 시각화 전체 파이프라인 단독 구현 및 검증

<br>


