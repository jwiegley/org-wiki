{
  description = "org-wiki — Org-native LLM Wiki tools for Emacs (read-only spike)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      buildFor =
        pkgs:
        let
          inherit (pkgs) lib;

          emacsPackages = pkgs.emacsPackagesFor pkgs.emacs-nox;

          # The nixpkgs MELPA snapshot predates the
          # mcp-server-lib-register-server API (0.4.0) that both the
          # user's live config and org-wiki-mcp.el use; pin the same
          # upstream commit the user runs.
          mcp-server-lib = emacsPackages.mcp-server-lib.overrideAttrs (_old: {
            version = "0.4.0-unstable-2026-06-10";
            src = pkgs.fetchFromGitHub {
              owner = "laurynas-biveinis";
              repo = "mcp-server-lib.el";
              rev = "2bb738efc39bf6bd01fa955590500eab890c37ba";
              hash = "sha256-WU/UZpfBMxkSd/dcDRwXkhNnPmBVaBblFWjCI4/c/Zw=";
            };
          });

          runtimeDeps =
            epkgs:
            with epkgs;
            [
              org
              org-roam
              org-ql
            ]
            ++ [ mcp-server-lib ];

          devDeps =
            epkgs: with epkgs; [
              undercover
              package-lint
              relint
            ];

          emacsForDev = emacsPackages.emacsWithPackages (epkgs: runtimeDeps epkgs ++ devDeps epkgs);

          packageSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./org-wiki.el
              ./org-wiki-mcp.el
              ./org-wiki-commands.el
            ];
          };

          checkSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./org-wiki.el
              ./org-wiki-mcp.el
              ./org-wiki-commands.el
              ./org-wiki-test.el
              ./org-wiki-commands-test.el
              ./Makefile
              ./flake.nix
              ./scripts
              ./baselines
            ];
          };

          org-wiki = emacsPackages.trivialBuild {
            pname = "org-wiki";
            version = "0.1.0";
            src = packageSrc;
            packageRequires = runtimeDeps emacsPackages;
            meta = {
              description = "Org-native LLM Wiki tools for Emacs (read-only spike)";
              homepage = "https://github.com/jwiegley/dot-emacs";
              license = lib.licenses.bsd3;
            };
          };

          # Run a Makefile target in an isolated copy of the source.
          # Byte-compiled files are removed first: `make' would treat
          # store-copied .elc files (all timestamps are epoch) as
          # current, and coverage must instrument sources, not .elc.
          mkMakeCheck =
            name: target: extraInputs:
            pkgs.runCommand "org-wiki-check-${name}"
              {
                nativeBuildInputs = [
                  emacsForDev
                  pkgs.gnumake
                ]
                ++ extraInputs;
              }
              ''
                cp -r ${checkSrc}/. build
                chmod -R u+w build
                cd build
                find . -name '*.elc' -delete
                export HOME="$TMPDIR"
                make ${target} EMACS=emacs
                touch $out
              '';
        in
        {
          package = org-wiki;

          devShell = pkgs.mkShell {
            packages = [
              emacsForDev
              pkgs.eask-cli
              pkgs.gnumake
              pkgs.lefthook
              pkgs.shfmt
              pkgs.nixfmt
              pkgs.lcov
            ];
          };

          checks = {
            build = org-wiki;
            compile = mkMakeCheck "compile" "build" [ ];
            tests = mkMakeCheck "tests" "test" [ ];
            lint = mkMakeCheck "lint" "lint" [ ];
            format = mkMakeCheck "format" "format-check" [
              pkgs.nixfmt
              pkgs.shfmt
            ];
            coverage = mkMakeCheck "coverage" "coverage-check" [ ];
            fuzz = mkMakeCheck "fuzz" "fuzz" [ ];
            # Benchmarks run to completion in the sandbox to prove the
            # harness works; the 5% regression gate runs in lefthook on
            # real hardware, where the committed baseline is valid.
            bench = mkMakeCheck "bench" "bench" [ ];
          };
        };
    in
    {
      packages = eachSystem (pkgs: rec {
        org-wiki = (buildFor pkgs).package;
        default = org-wiki;
      });

      devShells = eachSystem (pkgs: {
        default = (buildFor pkgs).devShell;
      });

      checks = eachSystem (pkgs: (buildFor pkgs).checks);

      formatter = eachSystem (pkgs: pkgs.nixfmt);
    };
}
