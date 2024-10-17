{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.users;

  # Taken directly from
  # https://github.com/NixOS/nixpkgs/blob/a3c0b3b21515f74fd2665903d4ce6bc4dc81c77c/nixos/modules/config/users-groups.nix#L498-L509
  idsAreUnique = set: idAttr: !(foldr (name: args@{ dup, acc }:
    let
      id = toString (getAttr idAttr (getAttr name set));
      exists = hasAttr id acc;
      newAcc = acc // (listToAttrs [ { name = id; value = true; } ]);
    in if dup then args else if exists
      then trace "Duplicate ${idAttr} ${id}" { dup = true; acc = null; }
      else { dup = false; acc = newAcc; }
    ) { dup = false; acc = {}; } (attrNames set)).dup;

  uidsAreUnique = idsAreUnique (filterAttrs (n: u: u.uid != null) cfg.users) "uid";
  gidsAreUnique = idsAreUnique (filterAttrs (n: g: g.gid != null) cfg.groups) "gid";

  group = import ./group.nix;
  user = import ./user.nix;

  toArguments = concatMapStringsSep " " (v: "'${v}'");
  toGID = v: { "${toString v.gid}" = v.name; };
  toUID = v: { "${toString v.uid}" = v.name; };

  isCreated = list: name: elem name list;
  isDeleted = attrs: name: ! elem name (mapAttrsToList (n: v: v.name) attrs);

  gids = mapAttrsToList (n: toGID) (filterAttrs (n: v: isCreated cfg.knownGroups v.name) cfg.groups);
  uids = mapAttrsToList (n: toUID) (filterAttrs (n: v: isCreated cfg.knownUsers v.name) cfg.users);

  createdGroups = mapAttrsToList (n: v: cfg.groups."${v}") cfg.gids;
  createdUsers = mapAttrsToList (n: v: cfg.users."${v}") cfg.uids;
  deletedGroups = filter (n: isDeleted cfg.groups n) cfg.knownGroups;
  deletedUsers = filter (n: isDeleted cfg.users n) cfg.knownUsers;

  packageUsers = filterAttrs (_: u: u.packages != []) cfg.users;

  # convert a valid argument to user.shell into a string that points to a shell
  # executable. Logic copied from modules/system/shells.nix.
  shellPath = v:
    if types.shellPackage.check v
    then "/run/current-system/sw${v.shellPath}"
    else v;

in

{
  options = {
    users.knownGroups = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of groups owned and managed by nix-darwin. Used to indicate
        what users are safe to create/delete based on the configuration.
        Don't add system groups to this.
      '';
    };

    users.knownUsers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of users owned and managed by nix-darwin. Used to indicate
        what users are safe to create/delete based on the configuration.
        Don't add the admin user or other system users to this.
      '';
    };

    users.groups = mkOption {
      type = types.attrsOf (types.submodule group);
      default = {};
      description = "Configuration for groups.";
    };

    users.users = mkOption {
      type = types.attrsOf (types.submodule user);
      default = {};
      description = "Configuration for users.";
    };

    users.gids = mkOption {
      internal = true;
      type = types.attrsOf types.str;
      default = {};
    };

    users.uids = mkOption {
      internal = true;
      type = types.attrsOf types.str;
      default = {};
    };

    users.forceRecreate = mkOption {
      internal = true;
      type = types.bool;
      default = false;
      description = "Remove and recreate existing groups/users.";
    };
  };

  config = {
    assertions = [
      { assertion = uidsAreUnique && gidsAreUnique;
        message = "UIDs and GIDs must be unique!";
      }
    ] ++ flatten (flip mapAttrsToList cfg.users (name: user: [
      # `Role accounts require name starting with _ and UID in 200-400 range.` from `sysadminctl -help`
      {
        assertion = user.isSystemUser -> hasPrefix "_" user.name;
        message = "System user ${user.name} does not begin with an underscore.";
      }
      {
        assertion = user.isSystemUser -> (user.uid == null || (user.uid >= 200 && user.uid <= 400));
        message = ''
          The UID ${toString user.uid} for ${user.name} is invalid for system users.

          You can set it to `null` for it to be automatically allocated or it must be between 200 and 400.
        '';
      }
      {
        assertion = user.isNormalUser -> (user.uid == null || user.uid >= 501);
        message = ''
          The UID ${toString user.uid} for ${user.name} is invalid for normal users.

          You can set it to `null` for it to be automatically allocated or it must be greater than 500.
        '';
      }
      {
        assertion = user.uid == null || ((user.uid >= 200 && user.uid < 400) -> user.isSystemUser);
        message = ''
          Please add to your config:

              users.users.${user.name}.isSystemUser = true;

          After this, you may remove the line specifying the UID if you would like it to get automatically allocated.
          If the user already exists, this won't change the existing user's UID and shouldn't cause any issues.
        '';
      }
      {
        assertion = user.uid == null || (user.uid >= 501 -> user.isNormalUser);
        message = ''
          Please add to your config:

              users.users.${user.name}.isNormalUser = true;

          After this, you may remove the line specifying the UID if you would like it to get automatically allocated.
          If the user already exists, this won't change the existing user's UID and shouldn't cause any issues.
        '';
      }
      {
        assertion = user.uid == null -> xor (user.isSystemUser) (user.isNormalUser);
        message = "Exactly one of `users.users.${user.name}.isSystemUser` and `users.users.${user.name}.isNormalUser` must be set.";
      }
    ]));

    users.users.root.uid = 0;

    users.gids = mkMerge gids;
    users.uids = mkMerge uids;

    system.activationScripts.groups.text = mkIf (cfg.knownGroups != []) ''
      echo "setting up groups..." >&2

      ${concatMapStringsSep "\n" (v: ''
        ${optionalString cfg.forceRecreate ''
          g=$(dscl . -read '/Groups/${v.name}' PrimaryGroupID 2> /dev/null) || true
          g=''${g#PrimaryGroupID: }
          if [[ "$g" -eq ${toString v.gid} ]]; then
            echo "deleting group ${v.name}..." >&2
            dscl . -delete '/Groups/${v.name}' 2> /dev/null
          else
            echo "[1;31mwarning: existing group '${v.name}' has unexpected gid $g, skipping...[0m" >&2
          fi
        ''}

        g=$(dscl . -read '/Groups/${v.name}' PrimaryGroupID 2> /dev/null) || true
        g=''${g#PrimaryGroupID: }
        if [ -z "$g" ]; then
          echo "creating group ${v.name}..." >&2
          dscl . -create '/Groups/${v.name}' PrimaryGroupID ${toString v.gid}
          dscl . -create '/Groups/${v.name}' RealName '${v.description}'
          g=${toString v.gid}
        fi

        if [ "$g" -eq ${toString v.gid} ]; then
          g=$(dscl . -read '/Groups/${v.name}' GroupMembership 2> /dev/null) || true
          if [ "$g" != 'GroupMembership: ${concatStringsSep " " v.members}' ]; then
            echo "updating group members ${v.name}..." >&2
            dscl . -create '/Groups/${v.name}' GroupMembership ${toArguments v.members}
          fi
        else
          echo "[1;31mwarning: existing group '${v.name}' has unexpected gid $g, skipping...[0m" >&2
        fi
      '') createdGroups}

      ${concatMapStringsSep "\n" (name: ''
        g=$(dscl . -read '/Groups/${name}' PrimaryGroupID 2> /dev/null) || true
        g=''${g#PrimaryGroupID: }
        if [ -n "$g" ]; then
          if [ "$g" -gt 501 ]; then
            echo "deleting group ${name}..." >&2
            dscl . -delete '/Groups/${name}' 2> /dev/null
          else
            echo "[1;31mwarning: existing group '${name}' has unexpected gid $g, skipping...[0m" >&2
          fi
        fi
      '') deletedGroups}
    '';

    system.activationScripts.users.text = mkIf (cfg.knownUsers != []) ''
      echo "setting up users..." >&2

      ${concatMapStringsSep "\n" (v: ''
        ${optionalString cfg.forceRecreate ''
          u=$(dscl . -read '/Users/${v.name}' UniqueID 2> /dev/null) || true
          u=''${u#UniqueID: }
          if [[ "$u" -eq ${toString v.uid} ]]; then
            echo "deleting user ${v.name}..." >&2
            sysadminctl -deleteUser '${v.name}' 2>/dev/null
          else
            echo "[1;31mwarning: existing user '${v.name}' has unexpected uid $u, skipping...[0m" >&2
          fi
        ''}

        u=$(dscl . -read '/Users/${v.name}' UniqueID 2> /dev/null) || true
        u=''${u#UniqueID: }
        if [[ -n "$u" && "$u" -ne "${toString v.uid}" ]]; then
          echo "[1;31mwarning: existing user '${v.name}' has unexpected uid $u, skipping...[0m" >&2
        else
          if [ -z "$u" ]; then
            echo "creating user ${v.name}..." >&2

            # When creating normal users, specifying `-home` will cause `sysadminctl`
            # to just assign the home directory instead of creating it.
            # When creating role accounts, specifying `-home` is ignored and will
            # be set to `/var/empty`.
            sysadminctl -addUser '${v.name}' \
              ${optionalString (v.uid != null) "-UID ${toString v.uid}"} \
              -GID ${toString v.gid} \
              -fullName '${v.description}' \
              ${optionalString v.isNormalUser "-home '${v.home}'"} \
              -shell ${lib.escapeShellArg (shellPath v.shell)}
          fi

          # Always update the properties on the user
          dscl . -create '/Users/${v.name}' PrimaryGroupID ${toString v.gid}
          dscl . -create '/Users/${v.name}' RealName '${v.description}'
          ${optionalString (v.isSystemUser) "dscl . -create '/Users/${v.name}' NFSHomeDirectory '${v.home}'"}
          ${optionalString v.createHome "createhomedir -cu '${v.name}'"}
          dscl . -create '/Users/${v.name}' UserShell ${lib.escapeShellArg (shellPath v.shell)}
          dscl . -create '/Users/${v.name}' IsHidden ${if v.isHidden then "1" else "0"}
        fi
      '') createdUsers}

      ${concatMapStringsSep "\n" (name: ''
        u=$(dscl . -read '/Users/${name}' UniqueID 2> /dev/null) || true
        u=''${u#UniqueID: }
        if [ -n "$u" ]; then
          if [ "$u" -gt 501 ]; then
            echo "deleting user ${name}..." >&2
            sysadminctl -deleteUser '${name}' 2> /dev/null
          else
            echo "[1;31mwarning: existing user '${name}' has unexpected uid $u, skipping...[0m" >&2
          fi
        fi
      '') deletedUsers}
    '';

    environment.etc = mapAttrs' (name: { packages, ... }: {
      name = "profiles/per-user/${name}";
      value.source = pkgs.buildEnv {
        name = "user-environment";
        paths = packages;
        inherit (config.environment) pathsToLink extraOutputsToInstall;
        inherit (config.system.path) postBuild;
      };
    }) packageUsers;

    environment.profiles = mkIf (packageUsers != {}) (mkOrder 900 [ "/etc/profiles/per-user/$USER" ]);
  };
}
