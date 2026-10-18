# SPDX-License-Identifier: Apache-2.0

null  :=
space := $(null) #
comma := ,

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export I3C_ROOT_DIR ?= $(abspath $(TEST_DIR)/../../../..)
export CALIPTRA_ROOT ?= $(I3C_ROOT_DIR)/third_party/caliptra-rtl
SRC_DIR := $(I3C_ROOT_DIR)/src
TRACK_FSM :=
export PATH := $(I3C_ROOT_DIR)/.venv/bin:/usr/local/bin:$(PATH)

TEST_FILES   = $(sort $(wildcard test_*.py))

MODULE      ?= $(subst $(space),$(comma),$(subst .py,,$(TEST_FILES)))
TOPLEVEL     = i3c_test_wrapper
CFG_NAME     = simple_target_only

override PLUSARGS := $(strip +FrontendBusInterface=SIMPLE $(PLUSARGS))

EXTRA_ARGS += -f $(I3C_ROOT_DIR)/src/i3c_simple.f $(I3C_ROOT_DIR)/verification/cocotb/top/lib_i3c_top/i3c_bus_harness.sv $(I3C_ROOT_DIR)/verification/cocotb/top/lib_i3c_top/i3c_test_wrapper.sv

include $(TEST_DIR)/../top_common.mk
