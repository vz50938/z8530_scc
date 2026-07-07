# Z8530 SCC — Implementation Notes

Status snapshot of the synthesizable Z8530 model in this directory
(`z8530_scc.sv`) and its testbench (`z8530_scc_tb.sv`).

---

## 1. Architecture

The model is split across **two clock domains**:

| Domain | Clock | Contents |
|--------|-------|----------|
| **CPU / bus** | `clk` (20 MHz in the Lisa MiSTer build) | Bus interface, full register file, interrupt latches + `/INT`, RR read mux, modem (CTS/DCD) synchronizers |
| **Serial A** | `sclk_a` (= `sclk` or `pclk`, parameter-selected) | Channel A: BRG, TX/RX FSMs, BREAK detect, error flags, external clock-pin syncs for `rxca`/`txca`/`rxda`, config-byte syncs for `wr*_a` |
| **Serial B** | `sclk_b` (= `sclk` or `pclk`, parameter-selected) | Same as Serial A but for Channel B (`rxcb`/`txcb`/`rxdb`, `wr*_b`) |

The module has **three clock inputs**:
- `clk` — CPU/bus clock
- `sclk` — primary serial clock (intended ~3.6864 MHz, historical Lisa value)
- `pclk` — alternative serial clock (Zilog datasheet name)

Per-channel parameters `BRG_SRC_A` / `BRG_SRC_B` (default 1 each) select per
channel whether `sclk_a` / `sclk_b` is sourced from `sclk` (1) or `pclk` (0).
The split lets each channel run on a different baud-rate-source frequency
without runtime clock muxing. WR14[1] is currently stored only; runtime
selection would require a glitch-free clock mux.

The TX and RX byte FIFOs straddle the bus and per-channel serial domains
and are implemented as **asynchronous (Gray-pointer) FIFOs**:

- **TX FIFO (per channel)**: written on `clk` (CPU), read on `sclk_a`/`sclk_b` (TX FSM)
- **RX FIFO (per channel)**: written on `sclk_a`/`sclk_b` (RX FSM), read on `clk` (CPU)

```
                       clk domain
              ┌─────────────────────────┐
              │ register file (WR0..15) │
              │ RR read mux             │
              │ interrupt latches /INT  │
              └────┬───────────────┬────┘
            config │               │ status (per ch.)
           2FF→sync│               │←2FF←sync
                   ▼               ▼
   ┌──── sclk_a domain ────┐   ┌──── sclk_b domain ────┐
   │ BRG A                 │   │ BRG B                 │
   │ TX FSM A, RX FSM A    │   │ TX FSM B, RX FSM B    │
   │ BREAK detect A        │   │ BREAK detect B        │
   │ error flags A         │   │ error flags B         │
   └──┬──────────────┬─────┘   └──┬──────────────┬─────┘
      │ TX async FIFO A           │ TX async FIFO B
      │ (clk → sclk_a)            │ (clk → sclk_b)
      │ RX async FIFO A           │ RX async FIFO B
      │ (sclk_a → clk)            │ (sclk_b → clk)
      ▼                           ▼
```

---

## 2. Implemented features

- Dual independent full-duplex channels (A, B)
- **Asynchronous mode only**: start / 5–8 data bits / optional parity / 1–2 stop bits
- Programmable baud-rate generator per channel, **real-Z8530 timing**:
  `baud = sclk / (2 · (TC + 2) · ClockMode)`, `ClockMode ∈ {1,16,32,64}` from WR4[7:6]
- 4-byte async TX & RX FIFOs per channel (Gray-pointer CDC)
- Character length 5/6/7/8 (WR5[6:5] TX, WR3[7:6] RX)
- Parity: enable (WR4[0]) + even/odd (WR4[1], **datasheet-correct polarity**)
- Stop bits: WR4[3:2] decoded (see limitations for 1.5)
- Local loopback (WR14[4])
- Interrupts: RX / TX / Ext-Status, per-channel, with proper **IP/IE separation**
  (events latch regardless of enable; enables gate only `/INT` and the vector)
- Interrupt vector: RR2 read via Channel A is always the raw WR2 base; RR2 read
  via Channel B is always status-modified (per datasheet, independent of
  WR9[0] VIS). Status-High-Low select via WR9[4]
- WR2 and WR9 treated as **chip-wide shared** registers (writable via either channel)
- Modem control: RTS (WR5[1]), DTR (WR5[7]); status CTS/DCD in RR0, plus the
  `/SYNC` pin level in RR0[4] (Sync/Hunt — async-mode status input only)
- **Auto Enables (WR3[5])**: /CTS gates the transmitter and /DCD gates the
  receiver; clearing WR5[1] mid-transmission defers the /RTS deassert (via the
  clk-domain `rts_hold_*` latch) until the transmitter has fully drained (with
  Auto Enables off, /RTS follows WR5[1] immediately). Compiled in by parameter
  `AUTO_ENABLES_EN` (default 1); set to 0 to remove the gating logic.
- Ext/Status interrupts on CTS/DCD edges, masked by WR15[5]/WR15[3]
- BREAK (async): TX-side Send Break via WR5[4] forces TX line low; RX-side
  detector flags RR0[7] and (with WR15[7]) raises an Ext/Status interrupt

---

## 3. Clock-domain-crossing (CDC) inventory

CDC is per channel — Channel A flops live in `sclk_a` and Channel B in
`sclk_b`. Each direction below applies independently to A and B.

| Signal(s) | Direction | Mechanism |
|-----------|-----------|-----------|
| WR3/4/5/11/12/13/14 config bytes (`_a`, `_b`) | clk → sclk_a / sclk_b | 2-FF byte synchronizer (`*_s1`→`*_s`) |
| `tx_active`, BREAK flag, error flags, `tx_underrun` | sclk_a/b → clk | 2-FF bit synchronizer |
| CTS/DCD modem inputs for Auto Enables gating | pin → sclk_a/b | 2-FF bit synchronizer (`cts*_s_sync`/`dcd*_s_sync`); feed `tx_cts_ok_*`/`rx_dcd_ok_*` which gate the TX/RX FSMs together with the already-synced WR3[5] copy (`auto_en_*_s`) |
| TX "byte grabbed" event (TX int) | sclk_a/b → clk | toggle + 3-FF sync + XOR edge detect |
| WR0 error-reset cmd (110) | clk → sclk_a / sclk_b | toggle + 3-FF sync + XOR edge detect |
| WR9[7:6] channel/force reset | clk → sclk_a / sclk_b | stretched pulse + 2-FF sync |
| RX byte arrival (RX int) | sclk_a/b → clk | FIFO `rempty` falling-edge detect on clk |
| External clock pins (rxca/txca on A, rxcb/txcb on B) | pin → sclk_a/b → clk | 3-FF sync in sclk_a/b; level re-synced to clk |
| TX/RX byte data | both ways | async Gray-pointer FIFO (per channel) |
| `reset_n` deassertion | async → sclk_a / sclk_b | 2-FF reset synchronizer (`sreset_n_a`, `sreset_n_b`) |

---

## 4. Register support matrix

| Reg | Support | Notes |
|-----|---------|-------|
| WR0 | partial | reg pointer + Point-High; cmds 010 (reset ext/stat), 101 (reset TX int), 110 (error reset). Other cmds ignored |
| WR1 | partial | RX modes 01/10 collapsed; bits 7:5 (WAIT/DMA), bit 2 (parity special) unimplemented |
| WR2 | yes | shared vector base (writable A or B) |
| WR3 | yes | RX bits/char, RX enable (bit 0), Auto Enables (bit 5) |
| WR4 | partial | clock mode (x1/x16/x32/x64 all decoded), parity, stop bits; sync-mode encodings not honored |
| WR5 | yes | TX bits/char, TX enable, Send Break (4), RTS, DTR |
| WR6/WR7 | stored only | sync chars — no sync protocol implemented |
| WR9 | partial | MIE (3), Status H/L (4), reset cmds 7:6 (force + per-channel); VIS (0) stored only -- RR2_b always status-modified per datasheet, so VIS has no effect on RR2 reads; DLC/NV unimplemented |
| WR10 | stored only | misc; not acted upon |
| WR11 | yes | TX/RX clock source select (BRG vs external); RTxC-XTAL full-rate override (see §5.10) when WR11[7]=1 & RX/TX src=RTxC |
| WR12/13 | yes | BRG time constant |
| WR14 | partial | BRG enable (0), loopback (4); DPLL/echo/DTR-func unimplemented |
| WR15 | partial | CTS IE (5), DCD IE (3), Break/Abort IE (7) used; sync/zero-count unimplemented |
| RR0 | yes | RX avail, TX empty(=not full), CTS, DCD, Sync/Hunt (bit 4 = /SYNC pin level, async-mode status only), TX underrun, Break/Abort |
| RR1 | partial | overrun, parity err, All-Sent; framing/residue/EOF unimplemented |
| RR2 | yes | Ch A: raw WR2; Ch B: always status-modified (datasheet behavior, independent of WR9[0] VIS) |
| RR3 | yes | raw IP bits (Ch A only) |
| RR8 | yes | RX FIFO read |
| RR10 | partial | loop-sending bit only |
| RR12/13 | yes | BRG TC readback |
| RR15 | yes | echoes WR15 |

---

## 5. Known limitations

### 5.1 Forced / hardware reset — implemented

WR9[7:6] reset commands are implemented:

- `11` Force Hardware Reset — clears both channels' registers/FSMs/FIFOs/
  interrupts plus the shared WR2/WR9
- `10` Channel Reset A — clears channel A only (registers, BRG, TX/RX FSMs,
  FIFOs, interrupts); channel B and shared regs untouched
- `01` Channel Reset B — clears channel B only

Each command drives a per-channel soft reset (`rst_a_clk`/`rst_b_clk`, plus
`force_clk` for the shared registers) generated by a clk-domain stretch counter
(`RST_STRETCH = 96` cycles). The channel resets are 2-FF-synchronized into sclk
(`rst_a_sclk`/`rst_b_sclk`) so the sclk-domain FSMs/BRG and **both sides of each
async FIFO** are held in reset with overlap. The clk-side hold is long enough to
contain the full sclk-side reset window.

**Parameter `SOFT_RESET_EN` (default 1)**: set to 0 to compile out the soft-reset
logic. When disabled, the WR9[7:6] command decode is forced inactive, so the
stretch counters never load, `rst_*` stay 0, and all reset overrides / CDC
synchronizers become dead logic that synthesis prunes. WR9[7:6] then behaves as
before this feature (decoded into `wr9_a` but no reset action). Instantiate with
`z8530_scc #(.SOFT_RESET_EN(0)) u_scc ( ... );`.

Notes / known edge behavior:
- During a reset window, writes to that channel's registers are overridden back
  to 0 (reset has priority via last-assignment-wins), so CPU writes issued
  inside the ~4.8 us window are ignored — a driver should not write a channel
  while resetting it.
- A force reset stores the written WR9 byte for one cycle before `force_clk`
  clears it; `0xC0` has MIE=0 so no spurious interrupt enable results.
- There is a small deassert-skew tail (clk-side releases ~16 clk cycles before
  sclk-side) during which no traffic occurs; harmless for a quiesced reset.

### 5.2 Asynchronous only

No SDLC/HDLC, Bisync, or Monosync. WR6/WR7 (sync chars), CRC, DPLL, and Auto
Echo are not implemented. WR4[3:2]=`00` ("sync modes enable") is treated as
1 stop bit rather than entering sync mode.

The `/SYNCA` / `/SYNCB` pins are supported **only in their async-mode role**:
each is an input whose synchronized level is reflected in RR0[4] (Sync/Hunt),
with no other function (no interrupt, no data-path effect) — matching the
datasheet's async-receive description. Their sync-mode functions (external-sync
input, internal-sync character/flag-detect output) and the crystal-oscillator
option are not implemented.

### 5.3 Stop bits

WR4[3:2] decode: `11` → 2 stop bits; `00`/`01`/`10` → 1 stop bit.
**1.5 stop bits (`10`) is treated as 1** — no half-bit TX state yet. RX only
samples one stop-bit position regardless of configuration.

### 5.3a RX FIFO pop on control-port RR8 read

Reading the RX byte through the **control port with register pointer = 8**
(`reg_ptr_a/b == 4'd8`, `d_c == 0`) pops the RX FIFO just like a data-port
(`d_c == 1`) read does -- matching the Z8530 datasheet. **Parameter
`RR8_CTRL_POP` (default 1)** gates this; set to 0 to revert to data-port-only
pop semantics. Use 0 only if a specific driver does back-to-back control-port
RR8 reads expecting the same byte; default 1 is correct for most drivers
including Lisa OS 3.x.

### 5.4 RX interrupt modes collapsed

WR1[4:3] = `01` ("first character") and `10` ("all characters") behave
identically (interrupt on every received byte). Mode `11` ("special receive
condition only") disables RX interrupts entirely — there is no
special-receive-condition interrupt source. WR1[2] (parity = special
condition) is unimplemented.

### 5.5 No WAIT/DMA, no hardware INTACK / daisy chain

WR1[7:5] (WAIT/DMA control) unimplemented. `intack_n` is an unused input —
there is no INTACK bus cycle, no IUS (Interrupt Under Service) bits, and no
interrupt daisy-chain (WR9 DLC/NV unimplemented). `/INT` is a simple wired-OR
of enabled pending sources gated by MIE.

### 5.6 FIFO depth differs from silicon

Real Z8530: 3-deep RX, 1-deep TX. This model: **4-deep** TX and RX (chosen so a
standard power-of-two async FIFO works). "TX Buffer Empty" (RR0[2]) means
"not full" rather than the silicon's single-byte semantics. Functionally
transparent to typical drivers.

### 5.7 Baud-rate formula vs Lisa Uniplus Unix

This model uses the **datasheet `TC+2`** formula. Lisa Uniplus uses both
serial ports. On Channel B it programs `TC=0x0B` for 9600 baud — almost
certainly because the driver computes that TC assuming Channel B is
clocked from the same 4 MHz source as Channel A. On a real Lisa I/O
board Channel B is actually fed from 3.6864 MHz, and at that frequency
the datasheet-correct TC for 9600 baud is `0x0A`. The mismatched
assumption leaves Channel B running at ~8861 baud (7.7 % off) — outside
any UART's lock tolerance. Channel A is unaffected because its 4 MHz
source matches what Uniplus's TC table expects.

Two knobs are provided for compatibility:

1. **`BRG_SRC_A`/`BRG_SRC_B`** select which module clock input feeds each
   channel's BRG (`sclk` or `pclk`). Pick or feed a frequency that makes
   the driver's TC table land on the intended rate. For Uniplus, feeding
   Channel B a 4 MHz `pclk` would naturally make TC=0x0B produce
   ~9600 baud without any patching.
2. **`UNIPLUS_BAUD_PATCH_B` (default 0)** — when set to 1, the Channel B
   BRG substitutes `0x000A` for `0x000B` at the divisor input, giving
   exact 9600 baud at 3.6864 MHz for Uniplus's TC. RR12/RR13 still read
   back the value software wrote; only `0x000B` is rewritten. Channel A
   is unaffected — its 4 MHz source already makes Uniplus's TC values
   correct.

### 5.8 tx_underrun is a placeholder

`tx_underrun` is wired into RR0[6] but never set — TX underrun/EOM is not
detected.

### 5.9 Integration TODO — wrapper needs `sclk` and `pclk`

`z8530_scc.sv` has three clock inputs (`clk`, `pclk`, `sclk`), but the
wrapper (`z8530_scc_wrap.sv`) and `lisa_io_b.sv` have **not** been updated
to plumb the new inputs. A dedicated 3.6864 MHz PLL output (or an existing
suitable clock) needs to be routed to `sclk`; `pclk` can be tied to
`clk_sys` for now (or to a separate frequency if a per-channel build wants
to run one channel from something other than 3.6864 MHz). With both
`BRG_SRC_A=1` and `BRG_SRC_B=1` (defaults), only `sclk` matters for
operation — but Verilog-side, `pclk` must still be connected. The external
serial clock pins (`rxca`/`txca`/`rxcb`/`txcb`) remain tied to `1'b0` in
the Lisa build (BRG-only operation). The new `/SYNCA` / `/SYNCB` inputs must
likewise be plumbed in the wrapper — tie them to `1'b1` (deasserted) if unused,
so RR0[4] reads 0 rather than floating.

### 5.10 RTxC-from-XTAL full-rate clock (no routed pin clock)

The external serial-clock pins (`rxca`/`txca`/`rxcb`/`txcb`) are tied off in this
build, so selecting an RTxC/TRxC clock source normally yields a dead engine (the
pin's edge-detect never pulses). To support the common "RTxC driven by a crystal,
both RX and TX clocked from RTxC" configuration **without** routing a physical pin
clock, the per-channel parameters **`RTXC_XTAL_FULLRATE_A` / `RTXC_XTAL_FULLRATE_B`
(default 1)** detect the condition `WR11[7]=1` (RTxC=XTAL) **and** `WR11[6:5]=00`
(RX clock = RTxC) **and** `WR11[4:3]=00` (TX clock = RTxC). When that holds, the
channel's TX/RX clock-enable (`tx_clk_*_s`/`rx_clk_*_s`) is forced active every
`sclk` cycle — i.e. RTxC is treated as the `sclk` crystal.

- The WR4 clock-mode divide (×1/16/32/64) **still applies**, so the effective bit
  rate is `sclk / ClockMode` (e.g. Channel B ×16 at 3.6864 MHz → 230400 baud).
- TX and RX of a channel are forced together, so loopback stays bit-coherent.
- Set the parameter to 0 to compile the override out; that WR11 encoding then
  selects the (tied-off) RTxC pin and the engine stays idle, as before.
- ×1 clock mode under this override gives one bit per `sclk` cycle with no
  oversampling margin — fine for self-clocked loopback, fragile for external
  async injection. Use ×16 for normal operation.

---

## 6. Testbench (`z8530_scc_tb.sv`)

- Clocks: `clk` = 20 MHz (50 ns), `pclk` = 4 MHz (250 ns), `sclk` =
  ~3.69 MHz (271 ns). With `BRG_SRC_A=0`, **Channel A's serial engine is
  clocked from `pclk` (4 MHz)**; `BRG_SRC_B=1` keeps Channel B on `sclk`.
- **Bus protocol**: signals valid 2 `clk` cycles before/after `cs_n`; `cs_n`
  asserted for 5 `clk` cycles (`bus_write` / `bus_read` primitives)
- Baud: TC=1, ×16. Self-clocked loopback is baud-agnostic (TX and RX share
  the BRG), so absolute rate doesn't matter for the loopback/stress tests.
  For **external injection/sniffing**, bit periods are per channel:
  - `BIT_TIME_A_NS = 24000` — Channel A @ 4 MHz → **41667 baud** (24 µs/bit)
  - `BIT_TIME_NS   = 26042` — Channel B @ 3.6864 MHz → **38400 baud**
- External serial clock pins tied to 0 (BRG-only); `send_serial_byte(channel, …)`
  drives the RX data line at that channel's matching bit period (`BIT_TIME_A_NS`
  for A, `BIT_TIME_NS` for B). The TX-line sniffer samples `txda` at
  `BIT_TIME_A_NS`.

| Test | Purpose |
|------|---------|
| 1–5 | Register config / readback, BRG setup |
| 6, 7 | Single-byte loopback (Ch A, Ch B) |
| 8 | RX+TX interrupt via loopback (WR1=0x12) |
| 9, 10 | 512-byte random loopback stress (Ch A, Ch B) |
| 12 | XON/XOFF software flow-control (loopback, external RX, mixed) |
| 13 | "Hello world!" string loopback (Ch A, Ch B) |
| 14 | Extended interrupts: MIE gating, Ext/Status from CTS/DCD, RR2 raw (Ch A) / status-modified (Ch B) |
| 15 | BREAK round-trip via loopback: Send Break, RX detect, Ext int, error reset |
| 16 | WR0 command-code reg_ptr decode (Point High vs. cmds 011/101/111) |
| 17 | Auto Enables (WR3[5]): /CTS gates TX, /DCD gates RX, deferred /RTS deassert, regression with Auto Enables off |
| 18 | Auto Enables OFF data path: /CTS high still transmits, /DCD high still receives (mirror of Test 17 A/B, WR3[5]=0) |
| 19 | /SYNC pins: /SYNCA/B level reflected in RR0[4] (Sync/Hunt) on each channel; status only — a /SYNC edge raises no interrupt even with WR15[4]+MIE |
| 20 | x32 / x64 clock-mode loopback (Ch A): WR4[7:6]=10/11 round-trip a byte, exercising the widened sample counters (reach 31/63) |
| 21 | RTxC-from-XTAL full-rate override (WR11=0x80, RTXC_XTAL_FULLRATE_A) loopback on Ch A — byte round-trips with the engine clocked every sclk cycle |

(Test 11 — external x1 clock — was removed; external clock pins are tied off.)

Not exercised by the TB: parity round-trip, 2-stop-bit framing,
5/6/7-bit characters, RX overrun recovery, WR9 reset commands.

---

## 7. Suggested next steps (not done)

1. Plumb `sclk` through `z8530_scc_wrap.sv` and `lisa_io_b.sv` (dedicated
   3.6864 MHz PLL output).
2. (Closed) Lisa Uniplus `TC+1` compatibility — handled via the
   `BRG_SRC_A/B` parameter selecting an appropriate clock source.
3. Optional: true 1.5-stop-bit TX state; RX special-receive-condition source.
4. Optional: add a TB test for the WR9 reset commands (force + per-channel),
   verifying channel isolation and FIFO flush.
