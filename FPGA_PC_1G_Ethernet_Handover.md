# VCU118 FPGA-PC 1GbE Ethernet Handover

## 1. Project Goal

Xilinx VCU118 보드와 PC 사이에 1GbE Ethernet 통신 환경을 구축하고, FPGA 내부 추론 IP와 연동하여 대용량 데이터를 송수신하는 것이다.

최종 목표:
- PC → FPGA 입력 데이터 전송
- FPGA 내부 추론 IP 처리
- FPGA → PC 결과 전송
- GPU/PC vs FPGA 결과 비교 검증

**현재 단계**: L1 PHY/PCS/PMA 링크 안정화 진행 중.

---

## 2. Development Environment

- **FPGA board**: Xilinx VCU118 (xcvu9p)
- **PHY**: TI DP83867
- **Vivado**: 2018.3
- **Interface**: SGMII 1Gbps (DP83867 → FPGA GTH transceiver)
- **Reference clock**: 625 MHz from DP83867 (`phy_sgmii_clk_p/n`)

**주요 파일 경로**:
```
프로젝트 루트:
  D:\Research\04.DL_Random_correction\Vivado\vcu118_udp_1g_jy_pcs_an_20260616

Vivado 프로젝트:
  vivado_project\vcu118_udp_1g_jy_pcs_an.xpr

주요 RTL:
  rtl\fpga.v

제약 파일:
  constr\fpga_1g_comm.xdc

UART 디버그:
  rtl\uart_debug_tx.v
```

---

## 3. Communication Stack

```
L1: Physical / PCS-PMA
    PC NIC <-> RJ45 copper <-> DP83867 PHY <-> SGMII <-> FPGA GTH <-> bd_525a_pcs_pma_0

L2: Ethernet MAC
    GMII <-> FPGA Ethernet MAC

L3: IP / ARP

L4: UDP / Application
```

**현재 디버깅 위치**: L1 — DP83867 SGMII side ↔ FPGA PCS/PMA

PC ↔ DP83867 copper-side 1Gbps 링크는 정상. FPGA PCS/PMA 쪽 SGMII 링크가 불안정.

---

## 4. UART Debug Field Guide

UART 출력 형식:
```
PKT IDLE RXU=0 TXU=0 TXP=0 TXM=0 RG=000 RB=000 RF=000 GDV=000 GBY=000
PCS=xxxx PCD=xxxx PR=xxxx
BM=xxxx BS=xxxx PC=xxxx PS=xxxx C2=xxxx RC=xxxx
AN=xxxx LP=xxxx G9=xxxx GA=xxxx
X4=xxxx XS=xxxx X1=xxxx XP=xxxx XF=xxxx XR=xxxx
```

| Field | 의미 |
|-------|------|
| RXU | UDP RX 패킷 수 |
| RG | MAC RX good frame 수 |
| GDV | GMII RX_DV edge 수 |
| GBY | GMII RX byte 수 |
| PCS | 자체 packed PCS 진단 필드 (16bit) |
| PCD | pcspma_diag_vector (16bit) |
| PR | Xilinx PCS/PMA status_vector 원본 |
| GA | DP83867 1000BASE-T Status (0x000A) |
| XS | DP83867 SGMII_ANEG_STS (ext 0x0037) |
| X1 | DP83867 SGMIICTL1 (ext 0x00D3) |
| XP | DP83867 STRAP_STS1 (ext 0x006E) |
| XR | DP83867 extended 0x016F |
| RC | MDIO read cycle 카운터 |

---

## 5. PCS Field Decode

`PCS=xxxx` (pcspma_uart_status_vector, 16bit):
```
[15] tx_locked      — GTH CDR 락 여부 (핵심!)
[14] rx_locked
[13] tx_logic_reset
[12] rx_logic_reset
[11] phy_gmii_clk_en_int
[10] phy_gmii_clk_en_mac
[9:8] reserved/an_interrupt
[7]  phy_link_status — DP83867가 SGMII로 전송하는 copper link 상태
[2]  rudi_c          — config ordered set 수신 중
[1]  link_sync       — 링크 동기화
[0]  link_status     — PCS 내부 링크 완료
```

주요 상태값:
| PCS 값 | 의미 |
|--------|------|
| 0x0507 | tx_locked=0, link_sync=1, rudi_c=1, link_status=1 (CDR 미락) |
| 0x0500 | tx_locked=0, SGMIICTL1 disable 효과 (link_sync=0) |
| 0xC507 | tx_locked=1, phy_link_status=0 (CDR 락됨, PHY는 link_down 전송 중) |
| 0xC5C7 | **목표** — tx_locked=1, phy_link_status=1 (완전 연결) |

`PCD=xxxx` (pcspma_diag_vector, 16bit):
```
[15] config_valid_seen
[14] an_adv_seen
[13] an_restart_seen
[12] an_interrupt_seen
[9]  tx_locked
[8]  rx_locked
[5:0] counter[29:24]  (125MHz 기준, 7 증가/UART frame ≈ 938ms)
```

---

## 6. 확인된 버그 및 수정 이력

### 수정 완료

| # | 파일 | 내용 | 상태 |
|---|------|------|------|
| 1 | `constr/fpga_1g_comm.xdc` L131 | 625MHz `create_clock` 주석 해제 | ✅ |
| 2 | `rtl/fpga.v` L301 | `pcspma_config_vector` `5'b10000` → `5'b00001` (AN enable) | ✅ |
| 3 | `rtl/fpga.v` | BMCR `0x1340` → `0x1140` (copper AN restart bit 제거) | ✅ |
| 4 | `rtl/fpga.v` | GBCR `0x1B00` (Force Master 유지) | ✅ |
| 5 | `rtl/fpga.v` | CFG4 `0x10B0` 복원 (0x1030으로 변경 후 rudi_invalid 악화 → 복원) | ✅ |
| 6 | `rtl/fpga.v` | lock-drop 리셋 제거 (카운터 단조 증가로 변경) | ✅ |
| 7 | `rtl/fpga.v` | an_restart 타이밍 7.5s (`30'd937500016`) | ✅ |
| 8 | `rtl/fpga.v` | saturation 고착 버그 수정 (`counter==0x3fffffff` 조건 추가) | ✅ |
| 9 | `rtl/fpga.v` | SGMIICTL1 토글 states 49-57 추가 | ✅ |
| 10 | `rtl/fpga.v` | `toggle_cooldown_reg` (4bit) 추가 — 토글 후 ~8.4s 재억제 | ✅ (미빌드) |

### Bug 8 상세 — saturation 고착 버그

**증상**: counter가 `0x3FFFFFFF`(max)에 도달한 후 tx_locked=0이 되면, `an_restart_config=0` (counter≠937.5M)이라 리셋 조건이 불발 → 재시도 중단.

**수정** (`rtl/fpga.v` Lines 344-350):
```verilog
always @(posedge clk_125mhz_int) begin
    if (eth_rst_125mhz_int) begin
        pcspma_config_seq_reg <= 30'd0;
    end else if (!pcspma_tx_locked && (pcspma_an_restart_config || (pcspma_config_seq_reg == 30'h3fffffff))) begin
        pcspma_config_seq_reg <= 30'd0;
    end else if (pcspma_config_seq_reg != 30'h3fffffff) begin
        pcspma_config_seq_reg <= pcspma_config_seq_reg + 1'b1;
    end
end
```

### Bug 9-10 상세 — SGMIICTL1 토글 및 cooldown

**현상**: GA=7800 (copper 완전 연결) 전환 시 DP83867 SGMII TX 신호 특성 변경 → GTH CDR 드롭 (하드웨어 특성, 소프트웨어 타이밍만으로 해결 불가).

**해결책**: SGMIICTL1(ext 0x00D3) disable(0x0000) → enable(0x4000) 토글로 DP83867 SGMII 블록 재시작 → CDR 재락 유도.

**State machine** (`rtl/fpga.v`):
- **State 49** (gate): `!tx_locked && cooldown==0` → state 50 (토글), else state 13 (루프)
- **States 50-53**: SGMIICTL1 = 0x0000 write
- **States 54-57**: SGMIICTL1 = 0x4000 write, cooldown = 9 설정
- **State 57 → 13**: 루프 복귀

**cooldown**: 9 × 938ms ≈ 8.4초. CDR 재락 후 SGMII AN 완료 시간 확보.

**관찰된 UART 결과 (최신 빌드)**:
```
Frame 7:  0507, GA=7800  ← GA 전환으로 CDR 드롭
Frame 12: 0507, RC=134   ← SGMIICTL1 토글 시작
Frame 13: 0500           ← SGMIICTL1=0x0000 disable 효과
Frame 15: 0507           ← SGMIICTL1=0x4000 re-enable, counter 리셋
Frame 17: C507           ← tx_locked=1 달성! (counter=18, ~2.4s 후)
Frame 18: 0507           ← 자연 드롭 (~938ms 후)
```

C507은 달성됐으나 ~938ms 만에 다시 드롭. cooldown(Bug 10) 적용 전 결과.

---

## 7. 현재 RTL 상태

### `rtl/fpga.v` 주요 위치

| 라인 | 내용 |
|------|------|
| 301 | `wire [4:0] pcspma_config_vector = 5'b00001;` (AN enable) |
| 303-306 | config 타이머: valid=1s, an_adv=1s+8cyc, an_restart=7.5s |
| 344-350 | counter 리셋 로직 (saturation fix 포함) |
| 354 | `wire [15:0] pcspma_an_config_vector = 16'hD801;` |
| ~540 | `toggle_cooldown_reg` 선언 (4bit) |
| 1007-1012 | State 49: SGMIICTL1 토글 gate (cooldown 조건 포함) |
| 1065-1070 | State 57: SGMIICTL1 re-enable + cooldown=9 설정 |

### MDIO 상태 머신 요약

```
States 0-3:   CFG4(0x0031) = 0x10B0
States 4-7:   SGMIICTL1(0x00D3) = 0x4000 (초기화)
States 44-47: ext 0x016F = 0x0015
States 8-12:  PHYCTRL, CFG2, ANAR, GBCR(0x1B00), BMCR(0x1140)
States 13-43: 연속 읽기 루프 (slot 0-15, ~938ms/loop)
State 49:     토글 gate — !tx_locked && cooldown==0 → state 50
States 50-57: SGMIICTL1 disable → enable 토글
State 57→13:  루프 복귀
```

---

## 8. 다음 단계

### 빌드 및 검증 순서

1. **Vivado 재빌드** — toggle_cooldown_reg 변경 포함 bitstream 생성
2. **FPGA 프로그래밍** 후 UART 모니터
3. **확인 항목**:

| 필드 | 기대값 | 의미 |
|------|--------|------|
| PCS[15] | 1 (C507) | tx_locked=1 달성 |
| PCS[15:14] | 1,1 (C507 이상) | CDR 락 유지 |
| PCS | 0xC5C7 | 최종 목표 (phy_link_status=1) |
| XS | 0x0003 | SGMII AN 완료 |
| GDV, GBY | ≠ 0 | GMII RX 데이터 도달 |
| RG, RXU | ≠ 0 | MAC/UDP 정상 |

### cooldown 적용 후 기대 동작

```
Frame 15: SGMIICTL1 re-enable, cooldown=9
Frame 17: C507 달성 → cooldown=7 (매 루프 -1)
Frame 18-24: C507 유지 (cooldown이 0이 될 때까지 재토글 없음)
  → 이 구간에서 SGMII AN 완료 → C5C7 달성 기대
```

### C507 유지되는데 C5C7 안 될 경우

- XS 확인: `XS=0003`이면 SGMII AN 완료됨 → phy_link_status가 왜 0인지 조사
- `pcspma_an_restart_config` 재발사 타이밍 조정
- DP83867 SGMII AN 상태 (`XS` 필드) 상세 분석

---

## 9. 코드 수정 규칙

**Claude는 코드를 직접 수정하지 않는다.**  
모든 RTL/XDC 수정은 **Codex CLI** 또는 **사용자 수동 수정**으로만 진행.

Codex 실행 명령 (Windows):
```
"C:\Users\IDL\AppData\Local\OpenAI\Codex\bin\f1c7ee7a13db5fed\codex.exe" exec --sandbox workspace-write --skip-git-repo-check -C "<dir>" "<task>"
```

또는 Claude Code 내에서 `/codex:rescue` 사용 가능 (현재 설치됨).

---

## 10. 현재 한 줄 요약

```
GA=7800(copper 완전 연결) 전환 시 GTH CDR 드롭 발생.
SGMIICTL1 토글로 C507(tx_locked=1) 일시 달성됨.
toggle_cooldown(~8.4s) 적용 후 빌드하여 C5C7(완전 링크) 달성 시도 중.
```
