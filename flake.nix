{
  description = "KernelSU/Apatch/Magisk WebUI Module Template";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        moduleProp =
          let
            content = builtins.readFile ./module/module.prop;
            lines = pkgs.lib.splitString "\n" content;
            validLines = builtins.filter (l: l != "" && builtins.substring 0 1 l != "#") lines;
            parseLine =
              line:
              let
                parts = builtins.match "([^=]+)=(.*)" line;
              in
              if parts != null then
                {
                  name = builtins.head parts;
                  value = builtins.elemAt parts 1;
                }
              else
                null;
          in
          builtins.listToAttrs (map parseLine validLines);

        repoUrl = pkgs.lib.removeSuffix "/releases/latest/download/update.json" moduleProp.updateJson;

        updateJson = {
          inherit (moduleProp) version;
          versionCode = builtins.fromJSON moduleProp.versionCode;
          zipUrl = "${repoUrl}/releases/latest/download/${moduleProp.id}_${moduleProp.version}.zip";
          changelog = "${repoUrl}/releases/latest/download/CHANGELOG.md";
        };
      in
      {
        packages.default = pkgs.stdenvNoCC.mkDerivation {
          inherit (moduleProp) version;
          pname = moduleProp.id;

          src = self;

          nativeBuildInputs = with pkgs; [
            zip
            jq
          ];

          # zip -r $out/${moduleProp.id}_minimal_${moduleProp.version}.zip ./* -x flake.{nix,lock} README.md CHANGELOG.md LICENSE "banner.*"
          installPhase = ''
            mkdir --parents $out

            cd module
            for f in banner.*; do
              if [ -e "$f" ]; then
                echo "banner=$f" >> module.prop
                break
              fi
            done
            zip -r $out/${moduleProp.id}_${moduleProp.version}.zip ./*
            cd ..

            echo '${builtins.toJSON updateJson}' | jq . > $out/update.json
            cp CHANGELOG.md $out/
          '';
        };

        devShells.default = pkgs.mkShellNoCC {
          buildInputs = with pkgs; [
            android-tools
            inotify-tools
          ];
          packages = with pkgs; [
            (writeShellScriptBin "push_module" ''
              temp_dir=/data/local/tmp/${moduleProp.id}
              adb shell "rm -rf $temp_dir"
              adb shell "mkdir -p $temp_dir"
              adb push module/* "$temp_dir"
              target_dir=/data/adb/modules/${moduleProp.id}
              adb shell su -c "rm -rf '$target_dir'"
              adb shell su -c "mv '/data/local/tmp/${moduleProp.id}' '$target_dir'"
            '')
            (writeShellScriptBin "sync_folder" ''
              target=''${1:-module/webroot}
              target=''${target%/}

              if [ "$target" = "module" ] || [ "$target" = "." ]; then
                relpath=""
              elif [ "''${target#module/}" != "$target" ]; then
                relpath="''${target#module/}"
              else
                relpath="$target"
              fi

              if [ -n "$relpath" ]; then
                dest_path="/data/adb/modules/${moduleProp.id}/$relpath"
              else
                dest_path="/data/adb/modules/${moduleProp.id}"
              fi

              temp_dir="/data/local/tmp/${moduleProp.id}_sync"

              if [ -d "$target" ]; then
                adb shell "rm -rf '$temp_dir'"
                adb shell "mkdir -p '$temp_dir'"
                adb push "$target/." "$temp_dir"
                adb shell su -c "mkdir -p '$(dirname "$dest_path")'"
                adb shell su -c "rm -rf '$dest_path'"
                adb shell su -c "mv '$temp_dir' '$dest_path'"
              elif [ -f "$target" ]; then
                basename=$(basename "$target")
                adb push "$target" "/data/local/tmp/$basename"
                adb shell su -c "mkdir -p '$(dirname "$dest_path")'"
                adb shell su -c "mv '/data/local/tmp/$basename' '$dest_path'"
              else
                echo "Error: '$target' is not a valid file or directory" >&2
                exit 1
              fi
            '')
            (writeShellScriptBin "hotreload" ''
              folder=''${1:-module/webroot}
              while inotifywait --quiet --recursive --event close_write --event moved_to --event delete "$folder"; do sync_folder "$folder"; done
            '')
          ];

          shellHook = ''
            echo "🚀 KernelSU/Apatch/Magisk WebUI Module environment loaded!"
            echo "💡 Run 'hotreload <file or webroot by default>' to watch for changes"
            echo "💡 Run 'sync_folder <file or webroot by default>' to push manually"
          '';
        };
      }
    );
}
