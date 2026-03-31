# Month 03 — Wazuh SIEM 구성 및 Falco Talon SOAR 구축 (2026.05)

## 작업 개요

4월에 구축한 하이브리드 인프라 위에 실제 보안 탐지 및 자동 대응 파이프라인을 완성했다.

이달의 핵심 작업은 두 가지다.

첫째, Falcosidekick에서 Wazuh로 전송되는 syslog 메시지의 파싱 문제를 해결하기 위해
커스텀 디코더와 룰을 직접 작성하여 Falco 이벤트가 Wazuh 대시보드에 표시되도록 구성했다.

둘째, Falco Talon SOAR를 설치하고 위협 탐지 시 Pod를 자동으로 삭제하는 자동 대응 흐름을 구현했다.
이 과정에서 컨테이너 시작 시 발생하는 정상 동작을 탐지하여 무한루프가 발생하는 문제를 해결했다.

<br>

## 전체 파이프라인

<pre>
공격 발생 (delta-lab Pod)
    │
    ▼
Falco 런타임 탐지 (worker1 / proc.tty != 0 조건)
    │
    ▼
Falcosidekick 이벤트 라우팅
    ├── Syslog (UDP 5140) ──→ Wazuh SIEM (Rule 100620, Level 10)
    ├── Kafka ─────────────→ falco-events 토픽
    └── HTTP POST ─────────→ Falco Talon (Pod 자동 삭제)
</pre>

<br>

## 이달 작업 상세

### 1. Falco 커스텀 룰 수정

**배경**

기존 Delta Lab Sensitive File Read 룰은 `/etc/passwd`, `/etc/shadow` 파일 읽기를 모두 탐지한다.
그러나 Talon 자동 대응 연동 시 컨테이너 시작 과정(Node.js 초기화)에서도 `/etc/passwd`가 읽혀
무한루프가 발생하는 문제가 있었다.

**해결: proc.tty != 0 조건 추가**

| 상황 | proc.tty 값 | 탐지 여부 |
|---|---|---|
| kubectl exec -it (사용자 직접 접속) | 0이 아닌 값 | 탐지 |
| 컨테이너 시작 시 Node.js 초기화 | 0 | 제외 |
| runc:[1:CHILD] init (컨테이너 생성) | 0 | 제외 |

```bash
# configmap 수정
kubectl edit configmap falco-rules -n falco

# 수정 후 DaemonSet 재시작
kubectl rollout restart daemonset/falco -n falco
```

→ `configs/falco-custom-rules.yaml` 참고

---

### 2. Falco Talon SOAR 설치

Falco/Falcosidekick으로부터 보안 이벤트를 수신하여 자동 대응 조치를 수행하는 SOAR 도구.

| 항목 | 내용 |
|---|---|
| 역할 | 보안 이벤트 수신 → 자동 대응 실행 |
| 연동 | Falcosidekick → Talon (HTTP POST) |
| 대응 방식 | kubernetes:terminate (Pod 즉시 삭제) |
| 포트 | 2803/TCP (ClusterIP: 10.99.101.115) |

```bash
# 네임스페이스 생성
kubectl create namespace falco-talon

# Helm으로 설치
helm install falco-talon falcosecurity/falco-talon \
  --namespace falco-talon \
  --values configs/talon-values.yaml

# 설치 확인
kubectl get pods -n falco-talon
kubectl logs -n falco-talon deployment/falco-talon | head -5
# → 1 rule(s) has/have been successfully loaded
```

→ `configs/talon-values.yaml` 참고

---

### 3. Falcosidekick → Talon 연동

Falcosidekick이 Wazuh(Syslog)와 Talon 두 곳으로 이벤트를 동시에 전송하도록 설정했다.

```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --reuse-values \
  --set falcosidekick.config.talon.address=http://10.99.101.115:2803 \
  --set falcosidekick.config.talon.minimumpriority=warning
```

연동 확인

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick | tail -5
# Enabled Outputs: [Syslog Talon]
# Falcosidekick is up and listening on :2801
```

→ `configs/falcosidekick-upgrade.sh` 참고

---

### 4. 트러블슈팅 1 — Falco Talon 무한루프

**문제 상황**

공격 시뮬레이션 후 delta-lab Pod가 생성 즉시 삭제되는 무한루프 발생.
`kubectl get pods -n default -w`에서 Pending → ContainerCreating → Terminating 사이클이 반복됐다.

**원인 분석**

delta-lab(Node.js) 컨테이너가 시작 시 `/etc/passwd`를 내부적으로 읽는 동작을 Falco가 탐지.
Talon이 Pod를 삭제하면 Deployment가 새 Pod를 생성하고,
새 Pod 시작 시 또 `/etc/passwd`를 읽어 다시 탐지되는 무한 반복이 발생했다.

```
새 Pod 시작 → Node.js 초기화 → /etc/passwd 읽음
→ Falco 탐지 → Talon 삭제 → 새 Pod 생성 → 반복
```

**해결**

두 가지를 조합하여 해결했다.

방법 1 — Falco 커스텀 룰에 `proc.tty != 0` 조건 추가
```
condition: > ... and proc.tty != 0
```

방법 2 — Talon deduplication 설정
```yaml
config:
  deduplication:
    timeWindowSeconds: 30
```

**결과**

새로 생성된 Pod는 `proc.tty != 0` 조건과 deduplication 설정에 의해 재탐지되지 않고
안정적으로 Running 상태를 유지했다.

---

### 5. 트러블슈팅 2 — Wazuh Falco 이벤트 미수신

**문제 상황**

Falco는 정상적으로 위협을 탐지하고 Falcosidekick으로 이벤트를 전달하고 있었으나,
Wazuh SIEM 대시보드에 Falco 관련 알림이 표시되지 않았다.

| 구성요소 | 상태 |
|---|---|
| Falco 탐지 | 정상 (Warning 이벤트 발생) |
| Falcosidekick → Talon | 정상 (Pod 자동 삭제 작동) |
| Falcosidekick → Wazuh (Syslog UDP 5140) | 패킷 도달 확인 |
| Wazuh 대시보드 Falco 알림 | 미표시 |

**원인 분석**

Falcosidekick이 전송하는 syslog 메시지 형식:

```
<4>2026-05-26T12:52:34Z falco-falcosidekick-xxxxx Falco[1]: {JSON_PAYLOAD}
```

Wazuh 기본 JSON 디코더는 메시지 전체가 JSON일 때만 작동한다.
Syslog 헤더(`<4>2026...Falco[1]:`)가 JSON 앞에 붙어있어 파싱 실패 → Phase 2에서 `No decoder matched`.

**해결: 커스텀 디코더 + 커스텀 룰 작성**

```bash
# 디코더 적용
sudo tee /var/ossec/etc/decoders/falco_decoders.xml

# 룰 적용
sudo tee /var/ossec/etc/rules/falco_rules.xml

# 설정 검증
sudo /var/ossec/bin/wazuh-analysisd -t

# Wazuh 재시작
sudo systemctl restart wazuh-manager
```

logtest 검증 결과:

```
Phase 2: Completed decoding.
        name: 'falcosidekick-syslog'
        json_data: '"uuid":"...","output":"...",...'

Phase 3: Completed filtering (rules).
        id: '100620'
        level: '10'
        description: 'Falco Delta Lab Attack Detected'
** Alert to be generated.
```

**룰 계층 구조**

| 룰 ID | Level | 조건 | 설명 |
|---|---|---|---|
| 100600 | 0 | 데코더 매칭 | Falco 이벤트 식별 (베이스) |
| 100610 | 6 | priority=Notice | 낮은 우선순위 이벤트 |
| 100613 | 8 | priority=Warning | Warning 이벤트 |
| 100620 | 10 | Delta Lab 매칭 | delta-lab 공격 탐지 (최종 알림) |

→ `configs/wazuh-falco-decoder.xml` / `configs/wazuh-falco-rules.xml` / `configs/wazuh-apply.sh` 참고

---

### 6. 전체 파이프라인 검증

**공격 시뮬레이션**

```bash
# 창 1: Pod 상태 실시간 모니터링
kubectl get pods -n default -w

# 창 2: interactive 쉘 접속 후 민감 파일 접근
kubectl exec -it delta-lab-<pod이름> -n default -- /bin/sh
/ # cat /etc/passwd
```

**검증 결과**

| 단계 | 구성요소 | 결과 |
|---|---|---|
| 1. 공격 시뮬레이션 | kubectl exec | 접속 성공 |
| 2. 런타임 탐지 | Falco (worker1) | Warning 이벤트 탐지 |
| 3. 이벤트 전송 | Falcosidekick | POST OK (200) |
| 4. SIEM 수신 | Wazuh | Rule 100620 매칭, Alert 생성 |
| 5. 자동 대응 | Falco Talon | Pod 자동 삭제 후 재생성 |

**자동 대응 동작 흐름**

```
delta-lab-xxx  1/1  Running     → Terminating  (Talon이 Pod 삭제)
delta-lab-xxx  0/1  Terminating
delta-lab-yyy  0/1  Pending     (Deployment가 새 Pod 생성)
delta-lab-yyy  0/1  ContainerCreating
delta-lab-yyy  1/1  Running     (새 Pod 정상 실행, 무한루프 없음)
```

<br>

## 설정 파일 목록

| 파일 | 설명 |
|---|---|
| `configs/falco-custom-rules.yaml` | Falco 커스텀 룰 (proc.tty != 0 조건) |
| `configs/talon-values.yaml` | Falco Talon Helm values (deduplication 30초) |
| `configs/falcosidekick-upgrade.sh` | Falcosidekick Syslog + Talon 동시 전송 설정 |
| `configs/wazuh-falco-decoder.xml` | Wazuh 커스텀 디코더 (Syslog 헤더 파싱) |
| `configs/wazuh-falco-rules.xml` | Wazuh 커스텀 룰 (Rule 100600~100620) |
| `configs/wazuh-apply.sh` | 디코더/룰 적용 및 Wazuh 재시작 스크립트 |

<br>

## 5월 작업 결과

- Falco 커스텀 룰 `proc.tty != 0` 조건 추가 완료 (무한루프 방지)
- Falco Talon 설치 완료 (1 rule 로드, Pod 자동 삭제 확인)
- Falcosidekick 이중 전송 구성 완료 (Syslog + Talon)
- Wazuh 커스텀 디코더 2단계 작성 완료 (Syslog 헤더 파싱 해결)
- Wazuh 커스텀 룰 4단계 계층 구성 완료 (Rule 100620, Level 10)
- 전체 파이프라인 검증 완료 (공격 → 탐지 → SIEM → 자동 대응)
- Wazuh 대시보드 Rule 100620 알림 실시간 표시 확인

6월 작업: Grafana 모니터링 대시보드 구성, 전체 시스템 안정화 및 성과 검증
