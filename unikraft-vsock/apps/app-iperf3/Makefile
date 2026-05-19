UK_ROOT ?= $(PWD)/../../unikraft
UK_BUILD ?= $(PWD)/build
UK_APP ?= $(PWD)
LIBS_BASE = $(PWD)/../../libs
UK_LIBS ?= $(LIBS_BASE)/musl:$(LIBS_BASE)/iperf3:$(LIBS_BASE)/lwip

.PHONY: all

all:
	@$(MAKE) -C $(UK_ROOT) L=$(UK_LIBS) A=$(UK_APP) O=$(UK_BUILD)

$(MAKECMDGOALS):
	@$(MAKE) -C $(UK_ROOT) L=$(UK_LIBS) A=$(UK_APP) O=$(UK_BUILD) $(MAKECMDGOALS)
