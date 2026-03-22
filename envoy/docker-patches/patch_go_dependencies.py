from pathlib import Path


path = Path("/workspace/envoy-custom/envoy/bazel/dependency_imports.bzl")
text = path.read_text()
old = """    go_repository(
        name = "com_github_spf13_afero",
        importpath = "github.com/spf13/afero",
        sum = "h1:EaGW2JJh15aKOejeuJ+wpFSHnbd7GE6Wvp3TsNhb6LY=",
        version = "v1.10.0",
        build_external = "external",
    )"""
new = """    go_repository(
        name = "com_github_spf13_afero",
        importpath = "github.com/spf13/afero",
        sum = "h1:EaGW2JJh15aKOejeuJ+wpFSHnbd7GE6Wvp3TsNhb6LY=",
        version = "v1.10.0",
        build_external = "external",
        build_directives = [
            "gazelle:resolve go golang.org/x/text/runes @org_golang_x_text//runes",
            "gazelle:resolve go golang.org/x/text/transform @org_golang_x_text//transform",
            "gazelle:resolve go golang.org/x/text/unicode/norm @org_golang_x_text//unicode/norm",
        ],
    )"""
if old not in text:
    raise SystemExit("afero go_repository block not found")
text = text.replace(old, new)

old = """    go_repository(
        name = "org_golang_x_text",
        importpath = "golang.org/x/text",
        sum = "h1:zyQAAkrwaneQ066sspRyJaG9VNi/YJ1NfzcGB3hZ/qo=",
        version = "v0.21.0",
        build_external = "external",
    )"""
new = """    go_repository(
        name = "org_golang_x_text",
        importpath = "golang.org/x/text",
        sum = "h1:zyQAAkrwaneQ066sspRyJaG9VNi/YJ1NfzcGB3hZ/qo=",
        version = "v0.21.0",
        build_external = "external",
    )
    go_repository(
        name = "org_golang_x_mod",
        importpath = "golang.org/x/mod",
        sum = "h1:kQgndtyPBW/JIYERgdxfwMYh3AVStj88WQTlNDi2a+o=",
        version = "v0.6.0-dev.0.20220106191415-9b9b3d81d5e3",
        build_external = "external",
    )
    go_repository(
        name = "org_golang_x_sys",
        importpath = "golang.org/x/sys",
        sum = "h1:2QkjZIsXupsJbJIdSjjUOgWK3aEtzyuh2mPt3l/CkeU=",
        version = "v0.0.0-20220811171246-fbc7d0a398ab",
        build_external = "external",
    )
    go_repository(
        name = "org_golang_x_tools",
        importpath = "golang.org/x/tools",
        sum = "h1:VveCTK38A2rkS8ZqFY25HIDFscX5X9OoEhJd3quQmXU=",
        version = "v0.1.12",
        build_external = "external",
        build_directives = [
            "gazelle:resolve go golang.org/x/sys/execabs @org_golang_x_sys//execabs",
            "gazelle:resolve go golang.org/x/mod/module @org_golang_x_mod//module",
            "gazelle:resolve go golang.org/x/mod/semver @org_golang_x_mod//semver",
        ],
    )"""
if old not in text:
    raise SystemExit("x/text go_repository block not found")
text = text.replace(old, new, 1)

old = """    go_repository(
        name = "com_github_lyft_protoc_gen_star_v2",
        importpath = "github.com/lyft/protoc-gen-star/v2",
        sum = "h1:sIXJOMrYnQZJu7OB7ANSF4MYri2fTEGIsRLz6LwI4xE=",
        version = "v2.0.4-0.20230330145011-496ad1ac90a4",
        build_external = "external",
    )"""
new = """    go_repository(
        name = "com_github_lyft_protoc_gen_star_v2",
        importpath = "github.com/lyft/protoc-gen-star/v2",
        sum = "h1:sIXJOMrYnQZJu7OB7ANSF4MYri2fTEGIsRLz6LwI4xE=",
        version = "v2.0.4-0.20230330145011-496ad1ac90a4",
        build_external = "external",
        build_directives = [
            "gazelle:resolve go golang.org/x/tools/imports @org_golang_x_tools//imports",
        ],
    )"""
if old not in text:
    raise SystemExit("protoc-gen-star go_repository block not found")
path.write_text(text.replace(old, new))
