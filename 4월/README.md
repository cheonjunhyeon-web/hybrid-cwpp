# Month 02 — 물리서버 구축 및 AWS 연동 (2026.04)

## 작업 개요

3월에 구축한 AWS 인프라 위에 실제 워크로드를 올리고,
온프레미스 물리서버 3대를 Kubernetes HA 클러스터로 구성했다.
AWS EKS와 물리서버를 Site-to-Site VPN으로 연결하여
하이브리드 보안 파이프라인의 기반을 완성했다.

<br>

## 아키텍처 구성도

<pre>
AWS EKS (클라우드)                         온프레미스 (물리서버)
│                                          │
├── Worker Node 1 (AZ-A / Public Subnet)   ├── cp1 (192.168.1.10) - Control Plane
│   ├── WEB Pod                            │   ├── kube-apiserver
│   ├── Fast API Pod                       │   ├── etcd
│   ├── Falco DaemonSet                    │   ├── kube-scheduler
│   ├── Falcosidekick                      │   ├── kube-controller-manager
│   └── Pg Bou Pod                         │   └── Kafka Broker 0 (port 9092)
│                                          │
├── Worker Node 2 (AZ-B / Public Subnet)   ├── cp2 (192.168.1.11) - Control Plane
│   ├── WEB Pod                            │   ├── kube-apiserver
│   ├── Fast API Pod                       │   ├── etcd
│   ├── Falco DaemonSet                    │   ├── kube-scheduler
│   ├── Falcosidekick                      │   ├── kube-controller-manager
│   └── Pg Bou Pod                         │   └── Kafka Broker 1 (port 9092)
│                                          │
├── ALB (AZ-A, AZ-B 분산)                  └── cp3 (192.168.1.12) - Control Plane
│                                              ├── kube-apiserver
└── Private Subnet                             ├── etcd
    ├── 거래소 DB (RDS Primary)                ├── kube-scheduler
    ├── CWPP DB                                ├── kube-controller-manager
    └── Redis Cache Session                    └── Kafka Broker 2 (port 9092)

               Site-to-Site VPN (IPSec IKEv1)
    AWS VPC ←──────────────────────────────→ 물리서버
    VGW: vgw-09b98eaaf5e368266              CGW: 106.240.19.114
                                            실제 NIC: 211.170.162.113
</pre>

<br>

## 이달 작업 상세

### 1. 물리서버 3대 기본 설정

**서버 사양**

| 노드 | IP | CPU | RAM | Disk | OS |
|---|---|---|---|---|---|
| cp1 | 192.168.1.10 | 4 Core | 8GB | 500GB SSD | Ubuntu 22.04 LTS |
| cp2 | 192.168.1.11 | 4 Core | 8GB | 500GB SSD | Ubuntu 22.04 LTS |
| cp3 | 192.168.1.12 | 4 Core | 8GB | 500GB | Ubuntu 22.04 LTS |

전 노드 공통 설정: 스왑 비활성화 / 커널 모듈 로드 / sysctl 설정 / containerd 설치 / kubeadm·kubelet·kubectl 설치

→ `configs/k8s-init.sh` 참고

---

### 2. VIP 설정 (HAProxy + Keepalived)

Control Plane 3대의 API Server 앞단에 VIP(192.168.1.100)를 두어
단일 진입점을 만들고 로드밸런싱을 구성했다.
cp1 장애 시 Keepalived가 VIP를 cp2로 자동 이전한다.

| 항목 | 값 |
|---|---|
| VIP | 192.168.1.100 |
| MASTER | cp1 (priority 100) |
| BACKUP 1 | cp2 (priority 90) |
| BACKUP 2 | cp3 (priority 80) |

→ `configs/haproxy.cfg` / `configs/keepalived-master.conf` / `configs/keepalived-backup.conf` 참고

---

### 3. Kubernetes HA 클러스터 구성

물리 장비 3대를 전부 Control Plane으로 구성하여 단일 장애점(SPOF)을 제거했다.
Worker Node가 없는 대신 Control Plane에 Pod가 직접 스케줄링되도록 taint를 제거했다.

```bash
# cp1에서 클러스터 초기화
sudo kubeadm init \
  --control-plane-endpoint "192.168.1.100:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16

# Control Plane taint 제거
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

**HA 구성 결과**

| 컴포넌트 | 동작 방식 |
|---|---|
| API Server | 3대 Active-Active, VIP(192.168.1.100)로 부하 분산 |
| Scheduler | Leader Election으로 1대 Active, 나머지 Standby |
| Controller Manager | Leader Election으로 1대 Active, 나머지 Standby |
| etcd | Raft 합의 알고리즘, 과반수(2대) 동의 시 데이터 저장 |

→ `configs/k8s-init.sh` 참고

---

### 4. Cilium CNI 설치

eBPF 기반 네트워크 플러그인으로 기존 iptables 방식보다 성능이 뛰어나고,
Network Policy를 통한 Pod 간 트래픽 제어가 가능하다.

```bash
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=192.168.1.100 \
  --set k8sServicePort=6443
```

→ `configs/cilium-install.sh` 참고

---

### 5. Kafka 클러스터 분산 배치

Falco 보안 이벤트를 AWS EKS에서 물리서버로 스트리밍하기 위한 메시지 큐.
3대의 물리서버에 Broker를 1개씩 분산 배치하여 고가용성을 확보했다.

**Broker 구성**

| Broker | 서버 | Broker ID | 포트 | JVM Heap |
|---|---|---|---|---|
| Broker 0 | cp1 (192.168.1.10) | 0 | 9092 | 2GB |
| Broker 1 | cp2 (192.168.1.11) | 1 | 9092 | 2GB |
| Broker 2 | cp3 (192.168.1.12) | 2 | 9092 | 2GB |

**falco-events 토픽 생성**

```bash
kafka-topics.sh --create \
  --topic falco-events \
  --bootstrap-server 192.168.1.10:9092 \
  --partitions 3 \
  --replication-factor 3
```

- Partition: 3 (각 Broker에 1개씩)
- Replication Factor: 3 (모든 Broker에 복제)
- Zookeeper: cp1:2181 / cp2:2181 / cp3:2181

→ `configs/kafka-server-0.properties` / `kafka-server-1.properties` / `kafka-server-2.properties` 참고

---

### 6. EKS Worker Node 배포

3월에 생성한 EKS 클러스터에 실제 워크로드를 실행할 Worker Node를 추가했다.

| 항목 | 값 |
|---|---|
| 인스턴스 타입 | t3.medium |
| Node Group | 최소 2 / 최대 4 / 희망 2 |
| 배치 | Worker Node 1 (AZ-A), Worker Node 2 (AZ-B) |

```bash
aws eks update-kubeconfig \
  --region ap-northeast-2 \
  --name cwpp-eks-cluster

kubectl get nodes
```

---

### 7. Falco / Falcosidekick 배포

EKS Worker Node에 Falco를 DaemonSet으로 배포하여
컨테이너 런타임 이벤트를 실시간으로 탐지하도록 구성했다.
Falcosidekick이 탐지된 이벤트를 물리서버 Kafka로 라우팅한다.

```bash
helm install falco falcosecurity/falco \
  --namespace falco \
  --set falcosidekick.enabled=true \
  --set falcosidekick.config.kafka.hostport=192.168.1.10:9092 \
  --set falcosidekick.config.kafka.topic=falco-events
```

**Falcosidekick 라우팅**

| 목적지 | 프로토콜 | 주소 |
|---|---|---|
| Kafka (온프레미스) | TCP | 192.168.1.10:9092 |
| Wazuh (Syslog) | UDP | 물리서버 5140 |
| Falco Talon | HTTP | ClusterIP:2803 |

---

### 8. Site-to-Site VPN 구성

AWS EKS와 물리서버 간 보안 터널을 구성하여
Falcosidekick → Kafka / RDS 프라이빗 통신 경로를 확보했다.

**네트워크 구성**

| 구분 | 값 |
|---|---|
| AWS VPC CIDR | 10.0.0.0/16 |
| RDS 프라이빗 IP | 10.0.21.254 |
| 물리서버 NIC (left) | 211.170.162.113 |
| CGW 등록 IP (leftid) | 106.240.19.114 |
| VPN 소스 /32 | 100.110.110.3, 100.70.66.39, 100.98.215.80 |
| Tunnel1 Outside IP | 43.201.173.43 |
| Tunnel2 Outside IP | 52.79.124.155 |

**AWS 측 설정**

| 리소스 | ID |
|---|---|
| Customer Gateway | cgw-04a1d20655fbf8ea0 |
| Virtual Private Gateway | vgw-09b98eaaf5e368266 |
| VPN Connection | vpn-0e033f88854b6d3f5 |
| VPN 방식 | Static routes / IKEv1 / Policy-based |

**VPN Static Routes (온프레 → AWS)**

```
100.110.110.3/32 → VGW
100.70.66.39/32  → VGW
100.98.215.80/32 → VGW
```

**RDS Security Group 인바운드**

| DB | SG ID | 허용 규칙 |
|---|---|---|
| exchange-db | sg-052cf6b8b402bef4f | TCP 5432 from 100.x/32 3개 |
| cwpp-db | sg-006aa21487769b816 | TCP 5432 from 100.x/32 3개 |

**CIDR 충돌 해결**

Cilium이 10.0.0.0/16을 사용하고 AWS VPC도 10.0.0.0/16이라 라우팅 충돌 발생.

```
Cilium 로컬 대역 (유지): 10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24
AWS VPC 대역 (명시 라우트): 10.0.3.0/24 ~ 10.0.255.0/24 → via 211.170.162.1
```

→ `configs/ipsec.conf` / `configs/ipsec.secrets` / `configs/fix-vpn-routing.sh` / `configs/aws-vpn-routes.service` 참고

**검증 결과**

```bash
# 터널 상태
sudo ipsec statusall   # Tunnel1 ESTABLISHED 확인

# 라우팅 확인
ip route get 10.0.21.254
# → via 211.170.162.1 dev eno1

# RDS 포트 접속 (소스 IP 지정)
nc -zvw3 -s 100.70.66.39 exchange-db.c3q2qg6e6ewc.ap-northeast-2.rds.amazonaws.com 5432
# → succeeded

# DB 접속
psql -h 10.0.21.254 -U exchange_app -d exchange_db -c "SELECT version();"
```

<br>

## 설정 파일 목록

| 파일 | 설명 |
|---|---|
| `configs/haproxy.cfg` | HAProxy 로드밸런서 설정 |
| `configs/keepalived-master.conf` | cp1 Keepalived MASTER 설정 |
| `configs/keepalived-backup.conf` | cp2, cp3 Keepalived BACKUP 설정 |
| `configs/k8s-init.sh` | kubeadm 초기화 스크립트 |
| `configs/cilium-install.sh` | Cilium CNI 설치 스크립트 |
| `configs/kafka-server-0.properties` | Kafka Broker 0 (cp1) 설정 |
| `configs/kafka-server-1.properties` | Kafka Broker 1 (cp2) 설정 |
| `configs/kafka-server-2.properties` | Kafka Broker 2 (cp3) 설정 |
| `configs/ipsec.conf` | strongSwan VPN 설정 |
| `configs/ipsec.secrets` | PSK 설정 (실제값 제외) |
| `configs/fix-vpn-routing.sh` | VPN 라우팅 복구 스크립트 |
| `configs/aws-vpn-routes.service` | systemd 유닛 (재부팅 후 라우트 재적용) |

<br>

## 4월 작업 결과

- 물리서버 3대 Ubuntu 22.04 LTS 설치 및 초기 설정 완료
- HAProxy + Keepalived VIP(192.168.1.100) 구성 완료
- Kubernetes Control Plane HA 3대 구성 완료 (SPOF 제거)
- Cilium CNI 설치 및 네트워크 정책 구성 완료
- Kafka 클러스터 3대 분산 배치 완료 (falco-events 토픽 생성)
- EKS Worker Node 2대 배포 완료 (AZ-A, AZ-B)
- Falco / Falcosidekick DaemonSet 배포 완료
- Site-to-Site VPN Tunnel1 ESTABLISHED 확인
- RDS PostgreSQL 프라이빗 접속 및 DB 마이그레이션 완료

5월 작업: Wazuh SIEM 구성, Falco Talon SOAR 설치, 커스텀 룰/디코더 작성, 전체 파이프라인 검증
