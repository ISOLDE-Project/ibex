# ---------------------------------------------------------------------------
# isolde/mk/generate.mk
#
# ---------------------------------------------------------------------------

GEN_CFG       ?= $(PROJECT_DIR)/config/platform.yml
GEN_JOBS      ?= $(PROJECT_DIR)/config/jobs.yml
GEN_TEMPLATES ?= $(PROJECT_DIR)/templates
GEN_SCRIPT    ?= $(SCRIPTS_DIR)/gen_isolde_rtl.py
GEN_DEPS      := $(GEN_CFG) $(GEN_JOBS) $(GEN_SCRIPT) $(wildcard $(GEN_TEMPLATES)/*.j2)

GEN_RUN        = python3 $(GEN_SCRIPT) --config $(GEN_CFG) \
                   --template-dir $(GEN_TEMPLATES) --root $(ROOT_DIR)

# fusesoc consumes this one (ibex_pkg.core)
GEN_HWE_PKG   := $(ROOT_DIR)/rtl/isolde_hwe_cluster_pkg.sv
# bender consumes these two (vendor/isolde-soc/Bender.yml)
GEN_AIDA_PKG  := $(ROOT_DIR)/vendor/isolde-soc/rtl/aida_pkg.sv
GEN_RELAY     := $(ROOT_DIR)/vendor/isolde-soc/rtl/cluster/isolde_xif_relay.sv
# sw-build.mk consumes this one
GEN_LINK_LD   := $(PROJECT_DIR)/system/bsp/link.ld

GENERATED_FILES := $(GEN_HWE_PKG) $(GEN_AIDA_PKG) $(GEN_RELAY) $(GEN_LINK_LD)

.PHONY: generate check-generated clean-generated

## generate: re-render every file described by config/jobs.yml
generate: $(GENERATED_FILES)

# One recipe renders all four; the stamp keeps make from running it per target.
$(GENERATED_FILES): .generated.stamp ;
.generated.stamp: $(GEN_DEPS)
	$(GEN_RUN) --batch $(GEN_JOBS)
	@touch $@

## check-generated: fail if the committed files no longer match platform.yml
check-generated:
	$(GEN_RUN) --batch $(GEN_JOBS) --check

## clean-generated: drop the stamp so the next build re-renders
clean-generated:
	rm -f .generated.stamp
.PHONY: generate-env
generate-env:
	@echo "GEN_CFG=$(GEN_CFG)"
	@echo "GEN_JOBS=$(GEN_JOBS)"
	@echo "GEN_TEMPLATES=$(GEN_TEMPLATES)"
	@echo "GEN_SCRIPT=$(GEN_SCRIPT)"
	@echo "GEN_DEPS=$(GEN_DEPS)"
	@echo "GEN_RUN=$(GEN_RUN)"
	@echo "GEN_HWE_PKG=$(GEN_HWE_PKG)"
	@echo "GEN_AIDA_PKG=$(GEN_AIDA_PKG)"
	@echo "GEN_RELAY=$(GEN_RELAY)"
	@echo "GEN_LINK_LD=$(GEN_LINK_LD)"
	
# --- wire the generated files into the real entry points -------------------
#
# fusesoc side (verilator/questa/vivado all elaborate ibex_pkg.core):
#   verilator_build questa_build vivado_project: $(GEN_HWE_PKG)
#
# bender side (flist/manifest generation reads Bender.yml sources):
#   $(BENDER_FLIST) bender_sources: $(GEN_AIDA_PKG) $(GEN_RELAY)
#
# software side (link.ld is an input to every .elf):
#   %.elf: $(GEN_LINK_LD)
#
# Add these prerequisites in verilator-build.mk / questa-build.mk / vivado.mk /
# bender-wrapper.mk / sw-build.mk respectively - one line each, no recipe
# changes.
