REPO_ROOT := /mnt/c/programming/go/reactive-pep-demo-fixed

.PHONY: build-receiver build-baseline build-grpc-cpp smoke-reactive smoke-baseline verify-no-event verify-oss-comparators correctness-report matrix-report install-metrics-server verify-mvp ci-smoke-local redeploy-envoy setup-notebook

build-receiver:
	g++ -std=c++20 -O2 -pthread -I$(REPO_ROOT) -o /tmp/reactive-mesh-receiver $(REPO_ROOT)/receiver/cpp/main.cpp -lssl -lcrypto

build-baseline:
	g++ -std=c++20 -O2 -pthread -I$(REPO_ROOT) -o /tmp/reactive-mesh-baseline $(REPO_ROOT)/baseline/opa/authz_service.cpp

build-grpc-cpp:
	cmake -S $(REPO_ROOT)/grpc -B /tmp/reactive-mesh-grpc-build
	cmake --build /tmp/reactive-mesh-grpc-build --target grpc-server grpc-client

smoke-reactive:
	$(REPO_ROOT)/scripts/smoke_reactive.sh

smoke-baseline:
	$(REPO_ROOT)/scripts/smoke_baseline.sh

verify-no-event:
	$(REPO_ROOT)/scripts/verify_no_event_stability.sh

verify-oss-comparators:
	$(REPO_ROOT)/scripts/verify_oss_comparators.sh

correctness-report:
	python3 $(REPO_ROOT)/scripts/generate_correctness_report.py \
		$(REPO_ROOT)/experiments/results/verify-mvp \
		$(REPO_ROOT)/experiments/results/verify-mvp/correctness-report.json \
		$(REPO_ROOT)/docs/evaluation/CORRECTNESS_REPORT.md

matrix-report:
	python3 $(REPO_ROOT)/experiments/generate_matrix_report.py \
		$(REPO_ROOT)/experiments/results/reactive-low.csv \
		$(REPO_ROOT)/experiments/results/reactive-medium.csv \
		$(REPO_ROOT)/experiments/results/reactive-high.csv \
		$(REPO_ROOT)/experiments/results/baseline-ext_authz-low.csv \
		$(REPO_ROOT)/experiments/results/baseline-ext_authz-medium.csv \
		$(REPO_ROOT)/experiments/results/baseline-ext_authz-high.csv \
		$(REPO_ROOT)/experiments/results/baseline-openfga-low.csv \
		$(REPO_ROOT)/experiments/results/baseline-openfga-medium.csv \
		$(REPO_ROOT)/experiments/results/baseline-openfga-high.csv \
		$(REPO_ROOT)/experiments/results/baseline-spicedb-low.csv \
		$(REPO_ROOT)/experiments/results/baseline-spicedb-medium.csv \
		$(REPO_ROOT)/experiments/results/baseline-spicedb-high.csv \
		--json-out $(REPO_ROOT)/experiments/results/matrix-report-full.json \
		--md-out $(REPO_ROOT)/docs/evaluation/MATRIX_REPORT.md

install-metrics-server:
	$(REPO_ROOT)/scripts/install_metrics_server.sh

verify-mvp:
	$(REPO_ROOT)/scripts/verify_mvp.sh

ci-smoke-local:
	$(REPO_ROOT)/scripts/run_act_smoke.sh

redeploy-envoy:
	$(REPO_ROOT)/scripts/redeploy_envoy_images.sh

setup-notebook:
	python3 -m venv $(REPO_ROOT)/.venv-notebook
	$(REPO_ROOT)/.venv-notebook/bin/pip install --upgrade pip
	$(REPO_ROOT)/.venv-notebook/bin/pip install -r $(REPO_ROOT)/experiments/requirements-notebook.txt
