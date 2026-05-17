UK_ROOT  ?= $(PWD)/../../unikraft
UK_LIBS  ?= $(PWD)/../../libs
UK_PLATS ?=

LIBS := $(UK_LIBS)/musl:$(UK_LIBS)/compiler-rt:$(UK_LIBS)/lwip

all:
	@$(MAKE) -C $(UK_ROOT) A=$(PWD) L=$(LIBS) P=$(UK_PLATS)

$(MAKECMDGOALS):
	@$(MAKE) -C $(UK_ROOT) A=$(PWD) L=$(LIBS) P=$(UK_PLATS) $(MAKECMDGOALS)
