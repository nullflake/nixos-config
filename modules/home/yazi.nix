{
  programs.yazi = {
    enable = true;
    settings = {
      opener = {
        edit = [
          {
            run = "micro %s";
            block = true;
            desc = "Edit with Micro";
          }
        ];
        image = [
          {
            run = "swayimg %s";
            orphan = true;
            desc = "Open with swayimg";
          }
        ];
        video = [
          {
            run = "mpv %s";
            orphan = true;
            desc = "Play with mpv";
          }
        ];
        audio = [
          {
            run = "mpv --no-video %s";
            orphan = true;
            desc = "Play with mpv";
          }
        ];
        pdf = [
          {
            run = "papers %s";
            orphan = true;
            desc = "Open with Papers";
          }
        ];
      };
      open.rules = [
        # Media types
        {
          mime = "image/*";
          use = "image";
        }
        {
          mime = "video/*";
          use = "video";
        }
        {
          mime = "audio/*";
          use = "audio";
        }
        {
          mime = "application/pdf";
          use = "pdf";
        }
      ]
      ++ (map
        (ext: {
          url = "*.${ext}";
          use = "edit";
        })
        [
          # Config / build / systemd / udev
          "conf"
          "cfg"
          "ini"
          "properties"
          "service"
          "rules"
          "patch"
          "diff"
          "cmake"
          # Markup / data formats
          "json"
          "toml"
          "yaml"
          "yml"
          "md"
          "txt"
          "xml"
          "csv"
          "log"
          "rst"
          "tex"
          # Shell / scripting
          "sh"
          "bash"
          "zsh"
          "fish"
          # Programming languages
          "nix"
          "lua"
          "py"
          "rs"
          "go"
          "c"
          "cpp"
          "h"
          "hpp"
          "java"
          "kt"
          "php"
          "rb"
          "sql"
          "js"
          "ts"
          "jsx"
          "tsx"
          "vue"
          "vim"
          "el"
          "proto"
          "graphql"
          # Web
          "css"
          "html"
          "htm"
        ]
      )
      ++ (map
        (name: {
          url = "*${name}";
          use = "edit";
        })
        [
          # Extensionless / dotfile config files
          "Makefile"
          "Dockerfile"
          ".dockerfile"
          ".gitignore"
          ".gitconfig"
          ".gitattributes"
          ".env"
          ".env.*"
          "LICENSE"
          "README"
          ".bashrc"
          ".zshrc"
          ".vimrc"
          ".curlrc"
          ".npmrc"
          ".editorconfig"
          "hosts"
          "fstab"
          "crontab"
          ".desktop"
          "CMakeLists.txt"
        ]
      )
      ++ [
        # Fallback: any remaining text mime, or empty/unrecognized files
        {
          mime = "text/*";
          use = "edit";
        }
        {
          mime = "inode/x-empty";
          use = "edit";
        }
      ];
    };
    keymap.manager.prepend_keymap = [
      {
        on = [ "." ];
        run = "hidden toggle";
      }
    ];
  };
}
