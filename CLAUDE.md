# CLAUDE.md — Session Restore / Working Context

Quick-start context for resuming work on the Z8530 SCC model. Read this first,
then `README.md` for full architecture detail.

---

## Project

Synthesizable **Z8530 SCC** (dual-channel async serial controller) in
SystemVerilog, targeting a Lisa / MiSTer build.

Design rev: **1.2** (Tests 1–24 pass; adds Sun2 interrupt fixes) — see the rev
banner in `z8530_scc.sv`.

| File | Role |
|------|------|
| `z8530_scc.sv` | Synthesizable RTL (DUT). **Considered correct — do not modify unless a real RTL bug is proven.** |
| `z8530_scc_tb.sv` | Testbench, Tests 1–24. `default_nettype none` (strict decl order). |
| `README.md` | Full implementation notes, register matrix, limitations. |

---

## How tests are run

- **The user runs the simulator manually** and pastes output back. There is
  **no Verilator/simulator available in this environment** — never attempt to
  run one. After editing, validate only with the editor's lint (`get_errors`).
- All tests (1–10, 12–24) currently **PASS** — the run ends with
  `RESULT: *** ALL CHECKS PASSED ***`. Each test prints per-check `PASS`/`FAIL`
  lines; the final summary is driven by a global `g_fail` counter (old-style
  tests increment it directly, named-block tests fold in their local `errs`).
  **Always read the RESULT line** — individual tests print FAIL inline but don't
  stop the run, so a silent failure is only caught by the summary.
- Test 6 previously had a latent bug (silently failing): Test 2 queued 0x55
  into the TX FIFO with no clock, and it flushed out once the BRG started —
  corrupting Test 6's loopback and bleeding a byte into Test 8. Fixed with a
  Channel Reset A at the top of Test 6 + RX drains, and Test 8 hardened to
  actually verify the received byte. The `g_fail` summary was added at the same
  time so this class of silent failure can't recur.

---

## Clocking (critical)

Three clocks feed the DUT:

| Clock | TB period | Freq | Drives |
|-------|-----------|------|--------|
| `clk`  | 50 ns  | 20 MHz     | CPU/bus domain |
| `pclk` | 250 ns | **4 MHz**  | **Channel A** serial engine (`BRG_SRC_A=0`) |
| `sclk` | 271 ns | 3.6864 MHz | **Channel B** serial engine (`BRG_SRC_B=1`) |

- `wire sclk_a = (BRG_SRC_A != 0) ? sclk : pclk;` → with `BRG_SRC_A=0`,
  **Channel A runs off `pclk` (4 MHz)**, not `sclk`.
- Baud math (TC=1, ×16): bit = 96 source cycles.
  - Channel A @ 4 MHz → 24 µs/bit → **41667 baud** (`BIT_TIME_A_NS = 24000`)
  - Channel B @ 3.6864 MHz → 26.04 µs/bit → **38400 baud** (`BIT_TIME_NS = 26042`)
- **Self-clocked loopback is baud-agnostic** (TX & RX share the BRG). Absolute
  rate only matters for **external injection** (`send_serial_byte`) and the
  **TX-line sniffer** — both are tuned per channel.

Active build parameters: `SOFT_RESET_EN=1`, `RR8_CTRL_POP=1`, `BRG_SRC_A=0`,
`BRG_SRC_B=1`, `UNIPLUS_BAUD_PATCH_B=1`, `AUTO_ENABLES_EN=1`,
`RTXC_XTAL_FULLRATE_A=1`, `RTXC_XTAL_FULLRATE_B=1`, `RDWR_RESET_EN=1`.

`RTXC_XTAL_FULLRATE_A/B`: when set, programming `WR11[7]=1` (RTxC=XTAL) with
both RX (`WR11[6:5]=00`) and TX (`WR11[4:3]=00`) clocks = RTxC clocks that
channel's serial engine every `sclk` cycle (RTxC ≡ sclk) instead of from the
tied-off RTxC pin. WR4 clock-mode divide still applies → bit rate = sclk/ClockMode.

---

## Recent work (this session)

This session **did touch the RTL** (`z8530_scc.sv`) — four new features, each
with testbench coverage. All 22 tests pass.

1. **Test 18 — Auto Enables OFF regression (TB only).** Mirror of Test 17 A/B:
   with `WR3[5]=0`, `/CTS` high still transmits and `/DCD` high still receives
   (proves `tx_cts_ok`/`rx_dcd_ok` force to 1 when auto-en is off).
2. **`/SYNCA` / `/SYNCB` pins (RTL + Test 19).** New input ports, 3-FF clk-domain
   syncs (mirroring CTS/DCD), driving **RR0[4] (Sync/Hunt)** with the pin level.
   **Status only** per datasheet — no interrupt, no gating (deliberate choice).
   Always-on (no parameter). Test 19 checks RR0[4] tracks each pin + no `/INT`.
3. **RTxC-from-XTAL full-rate override (RTL + Test 21).** Per-channel params
   `RTXC_XTAL_FULLRATE_A/B` (default 1): when `WR11[7]=1` & RX src
   (`WR11[6:5]=00`) & TX src (`WR11[4:3]=00`) = RTxC, the TX/RX clock-enable is
   forced every `sclk` cycle (RTxC ≡ sclk) instead of from the tied-off pin.
   WR4 clock-mode divide still applies. Test 21 loopbacks under `WR11=0x80`.
4. **x32 / x64 clock modes (RTL + Test 20).** WR4[7:6] now fully decoded via
   `get_clk_mult`/`get_start_sample`; TX/RX sample counters widened `[3:0]→[5:0]`
   to reach 31/63. Previously `01/10/11` all collapsed to x16. Test 20 loopbacks
   under x32 and x64 on Channel A.
5. **/RD+/WR simultaneous hardware reset (RTL + Test 22).** Param
   `RDWR_RESET_EN` (default 1, needs `SOFT_RESET_EN`): `cs_n=0 & rd_n=0 &
   wr_n=0` (registered once) fires the WR9=0xC0 force-reset machinery
   (`force_hw_evt`). Verified — rev 1.1.
6. **Test 6 stale-byte fix + real summary (TB only).** A log run exposed Test 6
   silently failing: Test 2's unclocked 0x55 flushed out of the TX FIFO once the
   BRG started, corrupting Test 6's loopback and bleeding into Test 8. Fixed
   (Channel Reset A at top of Test 6 + RX drains; Test 8 now verifies the RX
   byte and its own Ch A IP bits). Added a global `g_fail` counter and an
   end-of-run `RESULT: *** ALL CHECKS PASSED / FAIL ***` line so no test can
   fail silently again. All green.
7. **Sun2 PR merged → rev 1.2 (RTL + Tests 23-24). Verified — all 24 pass.**
   Reviewed and applied a 3-part PR for Sun2 (NetBSD/SunOS `zs`) emulation:
   (i) an interrupt **IP now latches only when its IE is set** (RX=WR1[4:3],
   TX=WR1[1], Ext=WR1[0]); (ii) the **TX IP also clears on a data write**
   (`| tx_fifo_wen`), matching `zstty_txint`; (iii) **WR2/WR9 writable via
   Channel B** (the B-path was commented out). Added Test 23 (IP/IE gating +
   TX-IP clear-on-write) and Test 24 (shared regs via Ch B). Existing interrupt
   tests (8/14/15) all enable their IE before expecting an IP, so they stayed
   green; confirmed by a full run (rev 1.2, all 24 pass).

Prior-session work (kept for reference): pclk fixed to 4 MHz (`PCLK_PERIOD=250`),
per-channel external bit time (`BIT_TIME_A_NS=24000`), and the Test 16 `WR0=0x10`
sub-test rewrite — all testbench-only.

---

## Guardrails

- **Do not run any simulator.** The user runs it and pastes results.
- **Do not modify `z8530_scc.sv`** unless a genuine RTL bug is proven; the
  failures resolved so far were testbench timing/logic issues.
- **Do not change `BRG_SRC_A`** (0 is intentional — Channel A = 4 MHz).
- Channel B external injection must stay at `BIT_TIME_NS=26042`.
- Don't alter RR1 "All Sent" semantics.
- Don't create new markdown docs unless asked.
- Use `multi_replace_string_in_file` with solid context anchors; verify edits
  with `get_errors` (the TB is `default_nettype none`, so declaration order
  and lint cleanliness matter).

---

## Test map (`z8530_scc_tb.sv`)

| Test | Purpose |
|------|---------|
| 1–5  | Register config / readback, BRG setup |
| 6, 7 | Single-byte loopback (Ch A, Ch B) |
| 8    | RX+TX interrupt via loopback |
| 9, 10 | 512-byte random loopback stress (Ch A, Ch B) |
| 12   | XON/XOFF flow control (loopback, **external RX = Part C**, mixed) |
| 13   | "Hello world!" loopback (Ch A, Ch B) |
| 14   | Extended interrupts (MIE gating, CTS/DCD ext-status, RR2) |
| 15   | BREAK round-trip |
| 16   | WR0 command-code reg_ptr decode |
| 17   | Auto Enables (WR3[5]): /CTS gates TX, /DCD gates RX, deferred /RTS |
| 18   | Auto Enables OFF: /CTS and /DCD do **not** gate TX/RX (mirror of 17 A/B) |
| 19   | /SYNC pins: /SYNCA/B level tracks RR0[4] (Sync/Hunt); status only (no int) |
| 20   | x32 / x64 clock-mode loopback (Ch A): widened sample counters reach 31/63 |
| 21   | RTxC-XTAL full-rate override (WR11=0x80) loopback (Ch A) |
| 22   | /RD+/WR simultaneous hardware reset (RDWR_RESET_EN): regs clear, /INT off, post-reset loopback |
| 23   | IP requires IE (Sun2): RX/TX/Ext IP gated by its enable; TX IP also clears on data write |
| 24   | Shared WR2/WR9 writable via Channel B (MIE gates /INT; vector reads back on RR2) |

(Test 11 — external x1 clock — was removed; external clock pins tied to 0.)
