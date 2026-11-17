# Run from the Jetlag repository root with: make -f /path/to/this/Makefile <target>
# Playbook targets run the playbooks only. Render the matching vars file and prepare inventories first.

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# System configuration
# ---------------------------------------------------------------------------
SHELL := /bin/bash
# Resolved via PATH; override with an absolute path if needed.
YQ_BIN ?= /usr/bin/yq

# ---------------------------------------------------------------------------
# Inventory
# Point to the right inventory file, e.g. ansible/inventory/cloudXXX.local.
# Any target accepts: make <target> INV_FILE=/path/to/local/file
# ---------------------------------------------------------------------------
INV_DIR ?= ./ansible/inventory
# Tolerate a trailing slash in an override so paths in messages stay clean.
_INV_DIR := $(patsubst %/,%,$(INV_DIR))
INV_FILES = $(wildcard $(_INV_DIR)/*.local)
INV_FILE ?= $(if $(filter 1,$(words $(INV_FILES))),$(INV_FILES))

# ---------------------------------------------------------------------------
# YQ section
# ---------------------------------------------------------------------------
YQ_DIR ?= .
_YQ_DIR := $(patsubst %/,%,$(YQ_DIR))
YQ_FILE ?= $(_YQ_DIR)/all.yq

# Vars sections

VARS_DIR ?= ./ansible/vars
_VARS_DIR := $(patsubst %/,%,$(VARS_DIR))

# The hub and DU operator profiles both render to ansible/vars/sync-operator-index.yml,
# so the aggregate render has to pick exactly one. Override with OPERATOR_PROFILE=hub.
OPERATOR_PROFILE ?= du

# ---------------------------------------------------------------------------
# Target configuration
# Bandwidth limiting in Mbps for step5.2: 0 disables it; 1, 10, 20, 100, 1000
# are the values the source script offered.
# ---------------------------------------------------------------------------
BANDWIDTH ?= 100

# Host-specific values discovered by the all.yq update targets. Leave these
# empty for automatic discovery, or override them explicitly when needed.
BASTION_DNS_NAME ?=
BASTION_DATA_DISK ?=

# ---------------------------------------------------------------------------
# Every target here is phony: none of them produce a file of their own name,
# and the checks must run even if a file happens to share a target name.
# ---------------------------------------------------------------------------
.PHONY: help \
	check-tools check-inventory check-all-vars check-hv-vars check-network-vars \
	check-sync-operator-index-vars check-sync-ocp-release-vars \
	render-all render-network-impairments render-hv render-everything \
	render-sync-operator-index render-sync-operator-index-hub \
	render-sync-operator-index-du render-sync-ocp-release \
	remove-registry remove-gogs remove-object-store remove-assisted-service \
	remove-hv-metrics clean-bastion nuke-all \
	match-all-yq update-bastion update-bastion-dns update-bastion-data-disk \
	update-hv update-hv-dns update-hv-usage \
	step0-render-vars step1-create-inventory step2-setup-bastion step3-deploy \
	step3.1-setup-hypervisors step3.2-create-vms step3.3-delete-vms step3.4-replace-vms \
	step4-sync-operator-index step4.1-sync-hub-operators step4.2-sync-du-operators \
	step4.3-sync-ocp step5.1-hv-network-impairments step5.2-vm-bandwidth \
	create-inventory setup-bastion mno-deploy hv-setup hv-vm-create \
	hv-vm-delete hv-vm-replace sync-operator-index sync-operator-index-hub \
	sync-operator-index-du sync-ocp-release hv-network-impairments hv-vm-bandwidth \
	clean-deploy redeploy refresh-infra \
	print-endpoints print-active-endpoints

# Ordered flows: their steps must not overlap under make -j.
# The aggregate render writes several files and must stay serial too.
# Targets that both render and check the same vars file must stay serial under -j
# so check does not race the render.
# (GNU make >= 4.4 honours the prerequisite list; older make serialises everything.)
.NOTPARALLEL: step0-render-vars render-everything \
	step4-sync-operator-index step4.1-sync-hub-operators \
	step4.2-sync-du-operators step4.3-sync-ocp \
	step5.1-hv-network-impairments \
	clean-deploy redeploy refresh-infra \
	match-all-yq update-bastion update-hv

# ---------------------------------------------------------------------------
# Validation targets
# ---------------------------------------------------------------------------
# The expressions below are mikefarah/yq v4 syntax. The "yq" shipped by many
# distros (and by pip) is python-yq, a jq wrapper that cannot parse them, so
# probe the binary functionally instead of trusting its name.
check-tools:
	@command -v "$(YQ_BIN)" > /dev/null 2>&1 || { echo "Error: yq not found: $(YQ_BIN). Install mikefarah/yq v4 or set YQ_BIN=<path>." >&2; exit 1; }
	@printf 'probe: 1\n' | "$(YQ_BIN)" -e 'tag == "!!map"' > /dev/null 2>&1 || { \
		echo "Error: $(YQ_BIN) is not mikefarah/yq v4: $$("$(YQ_BIN)" --version 2>&1 | head -n 1)" >&2; \
		echo "       The yq packaged as an RPM or on PyPI is python-yq, a jq wrapper, and rejects these expressions." >&2; \
		echo "       Install mikefarah/yq v4 from https://github.com/mikefarah/yq/releases and set YQ_BIN=<path>." >&2; \
		exit 1; }

check-inventory:
	@if [ -z "$(INV_FILE)" ]; then \
		if [ $(words $(INV_FILES)) -eq 0 ]; then \
			echo "Error: No .local files found in $(_INV_DIR)" >&2; exit 1; \
		else \
			echo "Error: Multiple .local files found in $(_INV_DIR): $(INV_FILES). Specify one via INV_FILE=<file>" >&2; exit 1; \
		fi; \
	elif [ ! -f "$(INV_FILE)" ]; then \
		echo "Error: Specified inventory file '$(INV_FILE)' does not exist." >&2; exit 1; \
	fi

# $(1): vars file basename; $(2): command that prepares it.
define check-vars-file
	@test -s "$(_VARS_DIR)/$(1).yml" || { echo "Error: Missing or empty $(_VARS_DIR)/$(1).yml. Run $(2)." >&2; exit 1; }
	@"$(YQ_BIN)" -e 'tag == "!!map"' "$(_VARS_DIR)/$(1).yml" > /dev/null || { echo "Error: $(_VARS_DIR)/$(1).yml must contain a YAML mapping. Run $(2)." >&2; exit 1; }
endef

check-all-vars: check-tools
	$(call check-vars-file,all,make render-all)

check-hv-vars: check-tools
	$(call check-vars-file,hv,make render-hv)

check-network-vars: check-tools
	$(call check-vars-file,network-impairments,make render-network-impairments)

check-sync-operator-index-vars: check-tools
	$(call check-vars-file,sync-operator-index,make render-sync-operator-index-hub or make render-sync-operator-index-du)

check-sync-ocp-release-vars: check-tools
	$(call check-vars-file,sync-ocp-release,make render-sync-ocp-release)

# ---------------------------------------------------------------------------
# Host-specific all.yq updates
# ---------------------------------------------------------------------------

# Update the all section from the domain of the host running make. Override
# BASTION_DNS_NAME for hosts whose configured domain is not the desired value.
update-bastion-dns: check-tools
	@set -euo pipefail; \
	file="$(YQ_FILE)"; \
	test -s "$$file" || { echo "Error: Missing or empty YQ file: $$file" >&2; exit 1; }; \
	"$(YQ_BIN)" -e 'tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.all | tag == "!!map"' "$$file" > /dev/null; \
	dns="$(BASTION_DNS_NAME)"; \
	if [ -z "$$dns" ]; then dns=$$(hostname -d 2>/dev/null || true); fi; \
	dns=$${dns%.}; \
	if [[ ! "$$dns" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$$ ]]; then \
		echo "Error: Could not determine a valid host domain; got '$$dns'. Set BASTION_DNS_NAME=<domain>." >&2; exit 1; \
	fi; \
	old=$$("$(YQ_BIN)" -r '.all.base_dns_name // ""' "$$file"); \
	line=$$("$(YQ_BIN)" -e '.all.base_dns_name | line' "$$file"); \
	[[ "$$line" =~ ^[1-9][0-9]*$$ ]] || { echo "Error: Could not locate .all.base_dns_name in $$file." >&2; exit 1; }; \
	tmp=$$(mktemp "$$file.tmp.XXXXXX"); \
	trap 'rm -f "$$tmp"' EXIT; \
	cp -p -- "$$file" "$$tmp"; \
	awk -v target_line="$$line" -v target_value="$$dns" ' \
		NR == target_line { \
			if ($$0 !~ /^  base_dns_name:[[:space:]]*/) exit 2; \
			print "  base_dns_name: " target_value; changed = 1; next \
		} \
		{ print } \
		END { if (changed != 1) exit 3 } \
	' "$$file" > "$$tmp"; \
	BASE_DNS_NAME="$$dns" "$(YQ_BIN)" -e '.all.base_dns_name == strenv(BASE_DNS_NAME)' "$$tmp" > /dev/null; \
	mv -f -- "$$tmp" "$$file"; \
	trap - EXIT; \
	printf 'Updated %s: .all.base_dns_name: %s -> %s\n' "$$file" "$$old" "$$dns"

# Select the unique whole-disk NVMe device that does not back the root
# filesystem, then store its stable by-path link. BASTION_DATA_DISK can be
# used to select a specific device while retaining all safety checks.
update-bastion-data-disk: check-tools
	@set -euo pipefail; \
	file="$(YQ_FILE)"; \
	test -s "$$file" || { echo "Error: Missing or empty YQ file: $$file" >&2; exit 1; }; \
	"$(YQ_BIN)" -e 'tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.all | tag == "!!map"' "$$file" > /dev/null; \
	for tool in findmnt lsblk readlink; do \
		command -v "$$tool" > /dev/null 2>&1 || { echo "Error: Required tool not found: $$tool" >&2; exit 1; }; \
	done; \
	root_source=$$(findmnt -n -o SOURCE -T /); \
	root_source=$${root_source%%\[*}; \
	root_disks=(); \
	while read -r root_device root_type; do \
		[ "$$root_type" = disk ] || continue; \
		root_disks+=("$$(readlink -f -- "$$root_device")"); \
	done < <(lsblk -s -n -p -o PATH,TYPE "$$root_source" 2>/dev/null); \
	[ $${#root_disks[@]} -gt 0 ] || { echo "Error: Could not resolve the disk backing the root filesystem." >&2; exit 1; }; \
	is_root_disk() { \
		local candidate="$$1" root_disk; \
		for root_disk in "$${root_disks[@]}"; do [ "$$candidate" != "$$root_disk" ] || return 0; done; \
		return 1; \
	}; \
	disk="$(BASTION_DATA_DISK)"; \
	if [ -z "$$disk" ]; then \
		candidates=(); \
		while read -r device type transport; do \
			[ "$$type" = disk ] && [ "$$transport" = nvme ] || continue; \
			device=$$(readlink -f -- "$$device"); \
			if ! is_root_disk "$$device"; then candidates+=("$$device"); fi; \
		done < <(lsblk -d -n -p -o PATH,TYPE,TRAN); \
		if [ $${#candidates[@]} -ne 1 ]; then \
			echo "Error: Expected exactly one non-root whole-disk NVMe device; found $${#candidates[@]}." >&2; \
			if [ $${#candidates[@]} -gt 0 ]; then printf '  %s\n' "$${candidates[@]}" >&2; fi; \
			echo "Set BASTION_DATA_DISK=/dev/disk/by-path/<path> to select one explicitly." >&2; exit 1; \
		fi; \
		device="$${candidates[0]}"; \
		paths=(); shopt -s nullglob; \
		for path in /dev/disk/by-path/*-nvme-*; do \
			case "$$path" in *-part*) continue ;; esac; \
			[ -L "$$path" ] || continue; \
			[ "$$(readlink -f -- "$$path")" = "$$device" ] && paths+=("$$path"); \
		done; \
		if [ $${#paths[@]} -eq 0 ]; then \
			echo "Error: No stable /dev/disk/by-path NVMe link resolves to $$device." >&2; exit 1; \
		fi; \
		disk="$${paths[0]}"; \
	fi; \
	resolved=$$(readlink -f -- "$$disk" 2>/dev/null || true); \
	test -b "$$resolved" || { echo "Error: Bastion data disk is not a block device: $$disk" >&2; exit 1; }; \
	read -r disk_type disk_transport < <(lsblk -d -n -o TYPE,TRAN "$$resolved"); \
	[ "$$disk_type" = disk ] && [ "$$disk_transport" = nvme ] || { echo "Error: Bastion data disk must be a whole NVMe disk: $$disk" >&2; exit 1; }; \
	if is_root_disk "$$resolved"; then echo "Error: Refusing to use a root-backing disk as bastion data disk: $$disk" >&2; exit 1; fi; \
	old=$$("$(YQ_BIN)" -r '.all.bastion_data_disk // ""' "$$file"); \
	line=$$("$(YQ_BIN)" -e '.all.bastion_data_disk | line' "$$file"); \
	[[ "$$line" =~ ^[1-9][0-9]*$$ ]] || { echo "Error: Could not locate .all.bastion_data_disk in $$file." >&2; exit 1; }; \
	tmp=$$(mktemp "$$file.tmp.XXXXXX"); \
	trap 'rm -f "$$tmp"' EXIT; \
	cp -p -- "$$file" "$$tmp"; \
	awk -v target_line="$$line" -v target_value="$$disk" ' \
		NR == target_line { \
			if ($$0 !~ /^  bastion_data_disk:[[:space:]]*/) exit 2; \
			print "  bastion_data_disk: " target_value; changed = 1; next \
		} \
		{ print } \
		END { if (changed != 1) exit 3 } \
	' "$$file" > "$$tmp"; \
	BASTION_DATA_DISK="$$disk" "$(YQ_BIN)" -e '.all.bastion_data_disk == strenv(BASTION_DATA_DISK)' "$$tmp" > /dev/null; \
	mv -f -- "$$tmp" "$$file"; \
	trap - EXIT; \
	printf 'Updated %s: .all.bastion_data_disk: %s -> %s\n' "$$file" "$$old" "$$disk"

# Keep the hypervisor DNS value aligned with the all section.
update-hv-dns: check-tools
	@set -euo pipefail; \
	file="$(YQ_FILE)"; \
	test -s "$$file" || { echo "Error: Missing or empty YQ file: $$file" >&2; exit 1; }; \
	"$(YQ_BIN)" -e 'tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.all | tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.hv | tag == "!!map"' "$$file" > /dev/null; \
	dns=$$("$(YQ_BIN)" -r '.all.base_dns_name // ""' "$$file"); \
	if [[ ! "$$dns" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$$ ]]; then \
		echo "Error: .all.base_dns_name is not a valid domain: '$$dns'." >&2; exit 1; \
	fi; \
	old=$$("$(YQ_BIN)" -r '.hv.base_dns_name // ""' "$$file"); \
	line=$$("$(YQ_BIN)" -e '.hv.base_dns_name | line' "$$file"); \
	[[ "$$line" =~ ^[1-9][0-9]*$$ ]] || { echo "Error: Could not locate .hv.base_dns_name in $$file." >&2; exit 1; }; \
	tmp=$$(mktemp "$$file.tmp.XXXXXX"); \
	trap 'rm -f "$$tmp"' EXIT; \
	cp -p -- "$$file" "$$tmp"; \
	awk -v target_line="$$line" -v target_value="$$dns" ' \
		NR == target_line { \
			if ($$0 !~ /^  base_dns_name:[[:space:]]*/) exit 2; \
			print "  base_dns_name: " target_value; changed = 1; next \
		} \
		{ print } \
		END { if (changed != 1) exit 3 } \
	' "$$file" > "$$tmp"; \
	BASE_DNS_NAME="$$dns" "$(YQ_BIN)" -e '.hv.base_dns_name == strenv(BASE_DNS_NAME)' "$$tmp" > /dev/null; \
	mv -f -- "$$tmp" "$$file"; \
	trap - EXIT; \
	printf 'Updated %s: .hv.base_dns_name: %s -> %s\n' "$$file" "$$old" "$$dns"

# Hypervisor service usage follows whether the corresponding bastion services
# are enabled in the all section.
update-hv-usage: check-tools
	@set -euo pipefail; \
	file="$(YQ_FILE)"; \
	test -s "$$file" || { echo "Error: Missing or empty YQ file: $$file" >&2; exit 1; }; \
	"$(YQ_BIN)" -e 'tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.all | tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.hv | tag == "!!map"' "$$file" > /dev/null; \
	"$(YQ_BIN)" -e '.all.setup_bastion_registry | tag == "!!bool"' "$$file" > /dev/null || { echo "Error: .all.setup_bastion_registry must be a boolean." >&2; exit 1; }; \
	"$(YQ_BIN)" -e '.all.setup_hv_metrics | tag == "!!bool"' "$$file" > /dev/null || { echo "Error: .all.setup_hv_metrics must be a boolean." >&2; exit 1; }; \
	registry=$$("$(YQ_BIN)" -r '.all.setup_bastion_registry' "$$file"); \
	metrics=$$("$(YQ_BIN)" -r '.all.setup_hv_metrics' "$$file"); \
	old_registry=$$("$(YQ_BIN)" -r '.hv.use_bastion_registry // ""' "$$file"); \
	old_metrics=$$("$(YQ_BIN)" -r '.hv.setup_hv_metrics // ""' "$$file"); \
	registry_line=$$("$(YQ_BIN)" -e '.hv.use_bastion_registry | line' "$$file"); \
	metrics_line=$$("$(YQ_BIN)" -e '.hv.setup_hv_metrics | line' "$$file"); \
	[[ "$$registry_line" =~ ^[1-9][0-9]*$$ ]] || { echo "Error: Could not locate .hv.use_bastion_registry in $$file." >&2; exit 1; }; \
	[[ "$$metrics_line" =~ ^[1-9][0-9]*$$ ]] || { echo "Error: Could not locate .hv.setup_hv_metrics in $$file." >&2; exit 1; }; \
	tmp=$$(mktemp "$$file.tmp.XXXXXX"); \
	trap 'rm -f "$$tmp"' EXIT; \
	cp -p -- "$$file" "$$tmp"; \
	awk -v registry_line="$$registry_line" -v registry_value="$$registry" \
		-v metrics_line="$$metrics_line" -v metrics_value="$$metrics" ' \
		NR == registry_line { \
			if ($$0 !~ /^  use_bastion_registry:[[:space:]]*/) exit 2; \
			print "  use_bastion_registry: " registry_value; registry_changed = 1; next \
		} \
		NR == metrics_line { \
			if ($$0 !~ /^  setup_hv_metrics:[[:space:]]*/) exit 2; \
			print "  setup_hv_metrics: " metrics_value; metrics_changed = 1; next \
		} \
		{ print } \
		END { if (registry_changed != 1 || metrics_changed != 1) exit 3 } \
	' "$$file" > "$$tmp"; \
	"$(YQ_BIN)" -e '.hv.use_bastion_registry == .all.setup_bastion_registry and .hv.setup_hv_metrics == .all.setup_hv_metrics' "$$tmp" > /dev/null; \
	mv -f -- "$$tmp" "$$file"; \
	trap - EXIT; \
	printf 'Updated %s: .hv.use_bastion_registry: %s -> %s; .hv.setup_hv_metrics: %s -> %s\n' \
		"$$file" "$$old_registry" "$$registry" "$$old_metrics" "$$metrics"

# Run each child through an ordered recursive make. This keeps the children
# independently callable, remains serial under make -j, and works with GNU
# Make releases that do not support the .WAIT prerequisite separator.
update-bastion:
	+@$(MAKE) --no-print-directory update-bastion-dns
	+@$(MAKE) --no-print-directory update-bastion-data-disk

update-hv:
	+@$(MAKE) --no-print-directory update-hv-dns
	+@$(MAKE) --no-print-directory update-hv-usage

match-all-yq:
	+@$(MAKE) --no-print-directory update-bastion
	+@$(MAKE) --no-print-directory update-hv

# ---------------------------------------------------------------------------
# Rendering targets
# ---------------------------------------------------------------------------

render-all: check-tools
	"$(YQ_BIN)" '. *= (load("$(YQ_FILE)").all // {})' \
	"$(_VARS_DIR)/all.sample.yml" > "$(_VARS_DIR)/all.yml"

render-hv: check-tools
	"$(YQ_BIN)" '. *=? (load("$(YQ_FILE)").all // {}) | . *= (load("$(YQ_FILE)").hv // {})' \
	"$(_VARS_DIR)/hv.sample.yml" > "$(_VARS_DIR)/hv.yml"

render-network-impairments: check-tools
	"$(YQ_BIN)" '. *=? (load("$(YQ_FILE)").all // {}) | . *= (load("$(YQ_FILE)").network-impairments // {})' \
	"$(_VARS_DIR)/network-impairments.sample.yml" > "$(_VARS_DIR)/network-impairments.yml"

render-sync-operator-index: check-tools
	"$(YQ_BIN)" '. *= ((load("$(YQ_FILE)").all // {}) | pick(["operator_index_name","operator_index_tag", "catalogs_to_sync", "additional_images", "extra_images"]))' \
	"$(_VARS_DIR)/sync-operator-index.sample.yml" > "$(_VARS_DIR)/sync-operator-index.yml"

render-sync-operator-index-hub: check-tools
	"$(YQ_BIN)" '. *=? (load("$(YQ_FILE)").all // {}) | . *= (load("$(YQ_FILE)").sync-operator-index-hub // {})' \
	"$(_VARS_DIR)/sync-operator-index-hub.sample.yml" > "$(_VARS_DIR)/sync-operator-index.yml"

render-sync-operator-index-du: check-tools
	"$(YQ_BIN)" '. *=? (load("$(YQ_FILE)").all // {}) | . *= (load("$(YQ_FILE)").sync-operator-index-du // {})' \
	"$(_VARS_DIR)/sync-operator-index-du.sample.yml" > "$(_VARS_DIR)/sync-operator-index.yml"

render-sync-ocp-release: check-tools
	"$(YQ_BIN)" '. *=? (load("$(YQ_FILE)").all // {}) | . *= (load("$(YQ_FILE)").sync-ocp-release // {})' \
	"$(_VARS_DIR)/sync-ocp-release.sample.yml" > "$(_VARS_DIR)/sync-ocp-release.yml"
render-everything: check-tools render-all render-hv render-network-impairments \
	render-sync-operator-index render-sync-ocp-release

step0-render-vars: check-tools render-all

# ---------------------------------------------------------------------------
# Starting fresh target
# ---------------------------------------------------------------------------

remove-registry:
	(podman pod exists registry && podman pod stop registry; \
	podman pod exists registry && podman pod rm registry; \
	rm -rf /opt/jetlag/registry)

remove-gogs:
	(podman pod exists gogs && podman pod stop gogs; \
	podman pod exists gogs && podman pod rm gogs; \
	rm -rf /opt/jetlag/gogs)

remove-object-store:
	(podman pod exists object-store && podman pod stop object-store; \
	podman pod exists object-store && podman pod rm object-store; \
	rm -rf /opt/jetlag/rustfs)

remove-assisted-service:
	(podman pod exists assisted-service && podman pod stop assisted-service; \
	podman pod exists assisted-service && podman pod rm assisted-service; \
	rm -rf /opt/jetlag/assisted-service)

remove-hv-metrics:
	(podman pod exists hv-metrics && podman pod stop hv-metrics; \
	podman pod exists hv-metrics && podman pod rm hv-metrics; \
	rm -rf /opt/jetlag/hv-metrics)

# Use this one to nuke everything
nuke-all: hv-vm-delete
	(podman system reset -f; \
	rm -rf /opt/jetlag)

# This should be enough of a clean up
clean-bastion: remove-registry remove-gogs remove-object-store remove-assisted-service remove-hv-metrics

# ---------------------------------------------------------------------------
# Playbook targets
# ---------------------------------------------------------------------------

create-inventory: step1-create-inventory
step1-create-inventory: check-all-vars
	(time ansible-playbook ansible/create-inventory.yml)

setup-bastion: step2-setup-bastion
step2-setup-bastion: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/setup-bastion.yml)

mno-deploy: step3-deploy
step3-deploy: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/mno-deploy.yml)

hv-setup: step3.1-setup-hypervisors
step3.1-setup-hypervisors: check-inventory check-hv-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/hv-setup.yml)

hv-vm-create: step3.2-create-vms
step3.2-create-vms: check-inventory check-hv-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/hv-vm-create.yml --forks 50)

hv-vm-delete: step3.3-delete-vms
step3.3-delete-vms: check-inventory check-hv-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/hv-vm-delete.yml --forks 50)

hv-vm-replace: step3.4-replace-vms
step3.4-replace-vms: check-inventory check-hv-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/hv-vm-replace.yml --forks 50)

sync-operator-index: step4-sync-operator-index
step4-sync-operator-index: check-inventory render-sync-operator-index check-sync-operator-index-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/sync-operator-index.yml)

sync-operator-index-hub: step4.1-sync-hub-operators
step4.1-sync-hub-operators: check-inventory render-sync-operator-index-hub check-sync-operator-index-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/sync-operator-index.yml)

sync-operator-index-du: step4.2-sync-du-operators
step4.2-sync-du-operators: check-inventory render-sync-operator-index-du check-sync-operator-index-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/sync-operator-index.yml)

sync-ocp-release: step4.3-sync-ocp
step4.3-sync-ocp: check-inventory render-sync-ocp-release check-sync-ocp-release-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/sync-ocp-release.yml)

hv-network-impairments: step5.1-hv-network-impairments
step5.1-hv-network-impairments: check-inventory render-network-impairments check-network-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/hv-network-impairments.yml)

hv-vm-bandwidth: step5.2-vm-bandwidth
# The source script supplies vm_bandwidth via -e and prepares no vars file.
step5.2-vm-bandwidth: check-inventory
	(time ansible-playbook -i "$(INV_FILE)" ansible/hv-vm-bandwidth.yml --forks 10 -e vm_bandwidth=$(BANDWIDTH))

# ---------------------------------------------------------------------------
# Pre-defined commonly used flows
# ---------------------------------------------------------------------------
clean-deploy: step0-render-vars step1-create-inventory step2-setup-bastion step3-deploy \
	step3.1-setup-hypervisors step3.2-create-vms

redeploy: step3-deploy step3.4-replace-vms

refresh-infra: step3.3-delete-vms step2-setup-bastion step3.1-setup-hypervisors step3.2-create-vms

# ---------------------------------------------------------------------------
# Bastion service endpoints (troubleshooting guide).
# Columns: port|url-with-__HOST__|description
# ---------------------------------------------------------------------------
define BASTION_ENDPOINTS
8080|http://__HOST__:8080|On-prem assisted-installer GUI
8090|http://__HOST__:8090|On-prem assisted-installer API
8888|http://__HOST__:8888|On-prem assisted-image-service
8081|http://__HOST__:8081|HTTP server
5000|http://__HOST__:5000|Container registry (when setup_bastion_registry=true)
6443|https://__HOST__:6443|HAProxy API (when disconnected)
443|https://__HOST__:443|HAProxy HTTPS (when disconnected)
80|http://__HOST__:80|HAProxy HTTP (when disconnected)
10881|http://__HOST__:10881|Gogs HTTP (when setup_bastion_gogs=true)
10022|ssh://git@__HOST__:10022|Gogs git SSH (when setup_bastion_gogs=true)
53|__HOST__:53|Dnsmasq / CoreDNS
3000|http://__HOST__:3000|Grafana (hypervisor monitoring)
9090|http://__HOST__:9090|Prometheus (hypervisor monitoring)
9000|http://__HOST__:9000|RustFS S3 API (when setup_bastion_object_store=true)
9001|http://__HOST__:9001|RustFS web console (when setup_bastion_object_store=true)
endef
export BASTION_ENDPOINTS

print-endpoints:
	@host=$$(hostname -f); \
	while IFS='|' read -r port url desc; do \
		[ -n "$$port" ] || continue; \
		url=$${url//__HOST__/$$host}; \
		printf '%-55s  %s\n' "$$url" "$$desc"; \
	done <<< "$$BASTION_ENDPOINTS"

print-active-endpoints:
	@host=$$(hostname -f); \
	while IFS='|' read -r port url desc; do \
		[ -n "$$port" ] || continue; \
		timeout 1 bash -c "echo >/dev/tcp/$$host/$$port" >/dev/null 2>&1 || continue; \
		url=$${url//__HOST__/$$host}; \
		printf '%-55s  %s\n' "$$url" "$$desc"; \
	done <<< "$$BASTION_ENDPOINTS"; \
	true

# ---------------------------------------------------------------------------
help:
	@printf '%s\n' \
		'Render vars first, then run the corresponding playbook target.' \
		'Example: make render-hv && make hv-setup' \
		'Existing vars must be nonempty YAML mappings. Rendering replaces them only on success.' \
		''
	@printf '%s\n' 'Steps (left) and their playbook aliases (right):'
	@printf '  %-32s%s\n' \
		'step0-render-vars'              'render-vars' \
		'step1-create-inventory'         'create-inventory' \
		'step2-setup-bastion'            'setup-bastion' \
		'step3-deploy'                   'mno-deploy' \
		'step3.1-setup-hypervisors'      'hv-setup' \
		'step3.2-create-vms'             'hv-vm-create' \
		'step3.3-delete-vms'             'hv-vm-delete' \
		'step3.4-replace-vms'            'hv-vm-replace' \
		'step4.1-sync-hub-operators'     'sync-operator-index-hub' \
		'step4.2-sync-du-operators'      'sync-operator-index-du' \
		'step4.3-sync-ocp'               'sync-ocp-release' \
		'step5.1-hv-network-impairments' 'hv-network-impairments' \
		'step5.2-vm-bandwidth'           'hv-vm-bandwidth'
	@printf '\n%s\n' 'Individual render targets:'
	@printf '  %s\n' \
		'render-all' 'render-network-impairments' 'render-hv' \
		'render-sync-operator-index-hub' 'render-sync-operator-index-du' \
		'render-sync-ocp-release'
	@printf '\n%s\n' 'Flows (run their steps in order; safe under make -j):'
	@printf '  %-32s%s\n' \
		'clean-deploy'   'step0 -> 1 -> 2 -> 3 -> 3.1 -> 3.2' \
		'redeploy'       'step3 -> 3.4' \
		'refresh-infra'  'step3.3 -> 2 -> 3.1 -> 3.2'
	@printf '\n%s\n' 'Other:'
	@printf '  %-32s%s\n' \
		'match-all-yq' 'discover bastion settings, then align the hv section' \
		'update-bastion' 'update all bastion host-specific settings' \
		'update-bastion-dns' 'set all.base_dns_name from hostname -d' \
		'update-bastion-data-disk' 'set all.bastion_data_disk from the non-root NVMe disk' \
		'update-hv' 'align hv DNS and bastion-service usage with all' \
		'update-hv-dns' 'copy all.base_dns_name to hv.base_dns_name' \
		'update-hv-usage' 'map all bastion service settings into hv usage settings' \
		'print-endpoints' 'all bastion service URLs (hostname -f)' \
		'print-active-endpoints' 'same list, only TCP-reachable ports' \
		'propagate-all-vars' 'merge existing keys from all.yq into rendered vars (skips *.sample.yml)'
	@printf '\n%s\n' 'Common overrides:'
	@printf '  %-32s%s\n' \
		'INV_FILE=<path>'            'inventory file (required when $(_INV_DIR) holds several .local files)' \
		'OPERATOR_PROFILE=hub|du'    'which operator index step0-render-vars renders (default: $(OPERATOR_PROFILE))' \
		'BANDWIDTH=<Mbps>'           'vm_bandwidth for step5.2; 0 disables (default: $(BANDWIDTH))' \
		'BASTION_DNS_NAME=<domain>'  'override hostname -d for update-bastion-dns' \
		'BASTION_DATA_DISK=<path>'   'select the non-root whole-disk NVMe device explicitly' \
		'YQ_BIN=<path>'              'yq binary (default: $(YQ_BIN))' \
		'YQ_FILE=<path>'             'all.yq file to update or render (default: $(YQ_FILE))' \
		'YQ_DIR=<dir>'               'directory holding the .yq change files (default: $(_YQ_DIR))'
