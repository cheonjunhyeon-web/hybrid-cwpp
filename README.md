# 하이브리드 이상탐지 플랫폼 (Hybrid CWPP)

> AWS EKS + 온프레미스 Kubernetes 기반 컨테이너 런타임 보안 자동화 플랫폼

<br>

## 📌 프로젝트 개요

클라우드 보안에 대한 깊이 있는 학습과 CWPP(Cloud Workload Protection Platform) 구축 경험을 목표로 시작한 프로젝트다.

AWS EKS와 온프레미스 Kubernetes를 AWS Direct Connect로 연결한 하이브리드 보안 아키텍처를 구성했다.
Falco 기반 컨테이너 런타임 탐지, Kafka 이벤트 스트리밍, Falco Talon 자동 대응, Wazuh SIEM 중앙 분석을 통해
클라우드와 온프레미스 환경의 보안 이벤트를 실시간으로 수집하고 대응하는 통합 보안 모니터링 체계를 구축한다.

- 참여 인원: 4명
- 수행 기간: 2026.03 ~ 2026.06

<br>

## 🏗️ 아키텍처

<p align="center">
<img width="2351" height="1071" alt="통합보안 이상탐지 플랫폼 drawio" src="https://github.com/user-attachments/assets/0c1f3bab-4572-4a0e-b7f8-a84637cdf27f" />
</p>

AWS 클라우드에서 웹 서비스를 운영하면서 보안 모니터링 및 대응 시스템은 온프레미스 Kubernetes 클러스터에 구축하는 하이브리드 방식으로 설계했다.
클라우드의 확장성과 온프레미스의 데이터 주권 및 보안 통제를 동시에 확보한다.

<br>

## ⚙️ 전체 워크플로우

| 단계 | 설명 |
|---|---|
| 1. 탐지 | EKS 웹 서버 컨테이너에서 런타임 이벤트 발생 → Falco 이상행위 탐지 → Falcosidekick 이벤트 수집 |
| 2. 전송 | AWS Direct Connect를 통해 온프레미스 Kafka로 보안 이벤트 스트리밍 (저지연 전용선) |
| 3. 분석 | Kafka → Wazuh SIEM → Decoding / Analysis / Indexing 수행 → 위험도 판정 |
| 4. 대응 | 고위험 이벤트 → Falco Talon → 위협 파드 격리/삭제, EKS API 호출, Slack 알림 |
| 5. 시각화 | Wazuh Indexer 저장 데이터 → Grafana 실시간 대시보드 |

<br>

## 🖥️ 인프라 상세

### AWS 클라우드 환경

**VPC 구성 (cwpp-vpc: 10.0.0.0/16)**

| 서브넷 | CIDR | 구성 요소 |
|---|---|---|
| Public Subnet | 10.0.1.0/24 | Internet Gateway, NAT Gateway, EKS Worker Nodes, Web Server Pod, Falco DaemonSet, Falcosidekick |
| Private Subnet | 10.0.2.0/24 | RDS PostgreSQL Multi-AZ (거래소 DB / CWPP 이벤트 DB) |

**EKS 클러스터**

| 항목 | 값 |
|---|---|
| 클러스터명 | CWPP-EKS-Cluster-Main |
| Kubernetes 버전 | 1.28 |
| 인스턴스 타입 | t3.medium |
| Node Group | 최소 2 / 최대 4 / 희망 2 |
| AMI | Amazon Linux 2 |

**RDS 데이터베이스**

| 항목 | 값 |
|---|---|
| 엔진 | PostgreSQL 14.3 |
| 인스턴스 클래스 | db.t3.micro |
| Multi-AZ | 활성화 |
| 백업 보존 기간 | 7일 |
| 용도 | web 메인 DB / Falco 이벤트 저장 DB |

**AWS Direct Connect**

| 항목 | 값 |
|---|---|
| 연결 유형 | Dedicated Connection |
| 대역폭 | 1Gbps |
| VLAN | 100 |
| BGP ASN | 65000 (AWS) / 65001 (온프레미스) |
| 목적 | 온프레미스 Kafka 클러스터 연결 |

---

### 온프레미스 환경

**물리 서버 사양 (Control Plane 3대)**

| 노드 | IP | CPU | RAM | Disk | OS |
|---|---|---|---|---|---|
| cp1 | 192.168.1.10 | 4 Core | 8GB | 500GB SSD | Ubuntu 22.04 LTS |
| cp2 | 192.168.1.11 | 4 Core | 8GB | 500GB SSD | Ubuntu 22.04 LTS |
| cp3 | 192.168.1.12 | 4 Core | 8GB | 500GB | Ubuntu 22.04 LTS |

**Kafka 클러스터 분산 배치**

| Broker | 서버 | Broker ID | 포트 | JVM Heap |
|---|---|---|---|---|
| Broker 0 | cp1 | 0 | 9092 | 2GB |
| Broker 1 | cp2 | 1 | 9092 | 2GB |
| Broker 2 | cp3 | 2 | 9092 | 2GB |

**Kafka Topic: falco-events**

- Partition: 3 (각 Broker에 1개씩)
- Replication Factor: 3 (모든 Broker에 복제)
- Zookeeper: cp1:2181 / cp2:2181 / cp3:2181

<br>

## 🙋 본인이 수행한 역할

- Wazuh SIEM 기반 보안 이벤트 수집 및 필터링 구성
- Falco 이벤트를 Wazuh Rule과 연동하여 위험도 기반 이벤트 분류
- 고위험 이벤트 발생 시 Falco Talon을 통한 컨테이너 삭제 및 IP 차단 자동 대응 구현
- 탐지 이벤트 유형별 분류 기준 정리 및 대응 흐름 설계
- SIEM 대시보드 및 이벤트 상관분석 기능 확장

<br>

## 🛠️ 기술 스택

| 분류 | 기술 |
|---|---|
| 클라우드 인프라 | AWS EKS, AWS VPC, AWS RDS, AWS Direct Connect |
| 컨테이너 오케스트레이션 | Kubernetes (온프레미스 HA), kubeadm |
| 보안 탐지 및 대응 | Falco, Falcosidekick, Falco Talon |
| 이벤트 스트리밍 | Apache Kafka |
| SIEM | Wazuh Server, Wazuh Indexer (OpenSearch) |
| 모니터링 & 시각화 | Grafana, Nginx Ingress |
| 네트워크 보안 | Cilium Agent |
| 알림 | Slack |

<br>

## 📊 성과 및 결과

<p align="center">
<img width="2351" height="1071" alt="통합보안 이상탐지 플랫폼 drawio" src="https://github.com/user-attachments/assets/5eba2a1d-cfb4-47cd-91a6-faa06e55eee9" />

  <br>
  <em>Grafana 통합 보안 이벤트 모니터링 대시보드</em>
</p>

<p align="center">
   <img width="1355" height="650" alt="스크린샷 2026-06-10 오전 10 52 29" src="https://github.com/user-attachments/assets/72baae96-e816-4be4-9b25-e318530b8200" />
  <br>
  <em>HTTP 공격 로그 및 Falco 컨테이너 공격 탐지 현황</em>
</p>

**탐지 결과 요약 (2026.06.08 ~ 2026.06.10 기준)**

| 항목 | 결과 |
|---|---|
| Falco 탐지 이벤트 수 | 38건 |
| 공격자 IP 수 (웹 로그) | 11개 |
| 탐지 갱신 주기 | 5초 |
| 공격 후 대기 시간 | 10초 |

**전체 파이프라인 구현 완료**

| 항목 | 상태 |
|---|---|
| AWS VPC / EKS 클러스터 구성 | ✅ |
| 물리서버 3대 Kubernetes HA 구성 | ✅ |
| Kafka 클러스터 분산 배치 (3 Broker) | ✅ |
| Site-to-Site VPN 연결 | ✅ |
| Falco 런타임 탐지 | ✅ |
| Wazuh SIEM 커스텀 디코더 / 룰 | ✅ |
| Falco Talon 자동 대응 | ✅ |
| Grafana 통합 대시보드 | ✅ |

- AWS EKS와 온프레미스 Kubernetes를 VPN으로 연결한 하이브리드 보안 아키텍처 구현
- Falcosidekick → Syslog 메시지 파싱 문제 해결 (커스텀 디코더 직접 작성)
- Talon 무한루프 문제 해결 (proc.tty 조건 + deduplication 조합)
- Cilium CIDR 충돌 / IKEv1 협상 / CGW IP 불일치 등 VPN 트러블슈팅 직접 해결
- 탐지 → 분석 → 자동 대응 → 시각화 전체 파이프라인 구현 및 검증 완료

<br>

## 📎 트러블슈팅

[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) 참고
