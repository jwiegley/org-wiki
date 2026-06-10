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

          runtimeDeps =
            epkgs: with epkgs; [
              org
              org-roam
              org-ql
              mcp-server-lib
            ];

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
            ];
          };

          checkSrc = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./org-wiki.el
              ./org-wiki-mcp.el
              ./org-wiki-test.el
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
