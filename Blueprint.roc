app [config] {
    pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.11.0/EuSPs8vc71qJNFg29YzegvVRL1bR9pKqUYDHFiSCPTQ1.tar.zst",
}

import pf.Recipes

config = [
    Name("roc-platform-patcher"),

    Packages("nix", From(NixPackages("github:NixOS/nixpkgs/nixos-unstable"))),

    Environment("dev", [
        Programs([
            Fetch("roc", Recipes.roc_nightly("nightly-2026-10-28-bad769b")),
        ]),
        Tools([
            "nix#binutils", # nm, objcopy, ar
            "nix#zstd",
            "nix#gnutar",
            "nix#clang",
            # optional:
            # "nix#llvm",  # llvm-nm, llvm-objcopy, llvm-ar
        ]),
    ]),

    Shell("default", [Use("dev")]),

    Task("roc-version", [Use("dev"), Run(["roc", "version"])]),
    Task(
        "rpp-tools",
        [
            Use("dev"),
            Run([
                "sh",
                "-c",
                "command -v nm && command -v objcopy && command -v ar && command -v tar && command -v zstd && command -v clang",
            ]),
        ],
    ),
]
