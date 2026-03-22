from pathlib import Path


path = Path("/workspace/envoy-custom/envoy/bazel/python_dependencies.bzl")
text = path.read_text()
old = 'extra_pip_args = ["--require-hashes"],'
new = 'extra_pip_args = ["--require-hashes", "--timeout", "120", "--retries", "20", "--index-url", "https://pypi.ac.cn/simple"],'
if old not in text:
    raise SystemExit("base pip args block not found")
path.write_text(text.replace(old, new, 3))
