# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0



.section .text

default_exc_handler:
  jal x0, simple_exc_handler

# Machine software interrupt: cluster events from isolde_event_barrier.
#
# Unreachable in normal operation, because mstatus.MIE is left clear (see
# _start). It exists so that enabling MIE degrades gracefully instead of
# livelocking.
#
# The barrier's pending vector is STICKY, so a handler that merely returns
# would re-trap forever - mret restores MIE from MPIE and the source is
# still asserted. Disarming the enable mask deasserts
#     irq_software_i = |(evt_pending & core_evt_mask)
# immediately, while leaving CSR_ISOLDE_TILE_IP intact so the waiting code
# still observes which events completed. Callers re-arm the mask in
# isolde_evt_wait()/isolde_evt_wait_all().
#
# Clobbers no GPRs, so it needs no stack frame.
isolde_evt_isr:
  csrw  0x7c3, zero          # CSR_ISOLDE_TILE_INTR_EN = 0
  mret

#timer_handler:
#  jal x0, simple_exc_handler

reset_handler:
  /* set all registers to zero */
  mv  x1, x0
  mv  x2, x1
  mv  x3, x1
  mv  x4, x1
  mv  x5, x1
  mv  x6, x1
  mv  x7, x1
  mv  x8, x1
  mv  x9, x1
  mv x10, x1
  mv x11, x1
  mv x12, x1
  mv x13, x1
  mv x14, x1
  mv x15, x1
  mv x16, x1
  mv x17, x1
  mv x18, x1
  mv x19, x1
  mv x20, x1
  mv x21, x1
  mv x22, x1
  mv x23, x1
  mv x24, x1
  mv x25, x1
  mv x26, x1
  mv x27, x1
  mv x28, x1
  mv x29, x1
  mv x30, x1
  mv x31, x1

  .global _start
_start:
 
#ifdef CV32E40X
  # Enabling CV32E40X mstatus.MIE
  li      t0, 0x1
  csrrs   zero, mstatus, t0
  # Enabling CV32E40P SW interrupt (mie[3])
  li      t0, 0x8
  csrrs   zero, mie, t0
#elif defined(IBEX)
  # ===================================================================
  # DESIGN DECISION: mstatus.MIE stays CLEAR. mie[3] stays SET.
  # ===================================================================
  # In this system interrupts are a WAKEUP mechanism, not a control
  # transfer mechanism. Cluster completions (RedMulE tiles and the SPM
  # loader) are delivered as a sticky vector by isolde_event_barrier and
  # consumed by polling CSR_ISOLDE_TILE_IP; WFI only idles the core until
  # something arrives. See bsp/isolde_evt.h.
  #
  # This is architectural, not an Ibex quirk. RISC-V Privileged spec,
  # "Wait for Interrupt": the operation of WFI must be unaffected by the
  # global interrupt bits in mstatus, but should honour the individual
  # interrupt enables in mie; and WFI is required to resume for locally
  # enabled pending interrupts regardless of the global enable. So the two
  # enables do different jobs here:
  #
  #   mie[3]        = 1  -> individual enable. WFI honours it, so the core
  #                         wakes when the cluster asserts irq_software_i.
  #   mstatus.MIE   = 0  -> global enable. WFI ignores it, so it does not
  #                         block the wakeup; it only stops the trap being
  #                         taken. No handler is needed.
  #
  # Ibex implements exactly that: ibex_controller leaves SLEEP on
  #     irq_nm || irq_pending_i || debug_req_i || ...
  # where irq_pending = |(mip & mie) - no mstatus - while a trap needs
  #     irq_enabled = csr_mstatus_mie_i | (priv_mode_i == PRIV_LVL_U).
  # ibex_top likewise ungates the clock on
  #     clock_en = core_busy | debug_req | irq_pending | irq_nm.
  #
  # CAVEAT 1 (portability). The same spec section permits an
  # implementation to resume for any reason, so WFI may legally be a NOP.
  # WFI is therefore a power optimisation only: correctness comes from the
  # sticky barrier plus the re-test loop around every WFI in
  # bsp/isolde_evt.h. Never treat a WFI return as proof of completion.
  # Ibex already demonstrates this - SLEEP also exits on debug_req_i,
  # debug_mode_q and debug_single_step_i, so under a debugger every WFI
  # behaves as a NOP and the waits degrade to busy-spins.
  #
  # CAVEAT 2 (privilege). irq_enabled above is also true in U-mode
  # regardless of mstatus.MIE. This build never leaves M-mode
  # (PMPEnable=0, nothing mrets into U), but if U-mode is ever introduced
  # this decision stops protecting anything and the ISR below becomes
  # load-bearing.
  #
  # WHY NOT enable MIE and write a handler. Since the event vector became
  # sticky, an enabled completion asserts irq_software_i until software
  # clears it. A handler that only executes mret restores MIE from MPIE
  # and re-traps immediately: an infinite trap loop with no output, which
  # is worse than the single EXCEPTION!!! this used to produce. Any real
  # handler would have to clear the source or the mask, duplicating the
  # bookkeeping the waiting code already does on a second code path.
  #
  # A defensive handler is installed at vector 3 anyway (isolde_evt_isr,
  # above). It is unreachable while MIE is clear.
  #
  # Just for reference: Enabling interrupts globally. mstatus.MIE
  # li      t0, 0x8
  # csrrs   zero, mstatus, t0
  #
  # Enabling SW interrupt (mie[3]), see https://ibex-core.readthedocs.io/en/latest/03_reference/cs_registers.html#machine-interrupt-enable-register-mie
  li      t0, 0x8
  csrrs   zero, mie, t0
#else
  # Error: No supported core defined
  .error "Unsupported core: Please define CV32E40X or IBEX."
#endif



  /* Stack initialization */
  la   x2, _stack_start
  andi sp, x2, ~0x7      //aligning the stack pointer (sp) to an 8-byte boundary 

  /* clear BSS */
  la x26, _bss_start
  la x27, _bss_end

  bge x26, x27, zero_loop_end

zero_loop:
  sw x0, 0(x26)
  addi x26, x26, 4
  ble x26, x27, zero_loop
zero_loop_end:


main_entry:
  /* jump to startup program entry  */
  addi a0, x0, 0
  addi a1, x0, 0
  jal x1, startup
  /* If execution ends up here just put the core to sleep */
sleep_loop:
  wfi
  j sleep_loop

/* =================================================== [ exceptions ] === */
/* This section has to be down here, since we have to disable rvc for it  */

  .section .vectors, "ax"
  .option norvc;

  // All unimplemented interrupts/exceptions go to the default_exc_handler.
  .org 0x00
  .rept 3
  jal x0, default_exc_handler
  .endr

  // 3: machine software interrupt = ISOLDE cluster event vector.
  // Unreachable while mstatus.MIE is clear; present as a safety net.
  jal x0, isolde_evt_isr

  .rept 27
  jal x0, default_exc_handler
  .endr

  // reset vector
  .org 0x80
  jal x0, reset_handler