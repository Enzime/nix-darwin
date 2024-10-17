{ name, config, lib, ... }:

{
  options = with lib; {
    name = mkOption {
      type = types.str;
      default = name;
      description = ''
        The name of the user account. If undefined, the name of the
        attribute set will be used.
      '';
    };

    description = mkOption {
      type = types.str;
      default = "";
      example = "Alice Q. User";
      # This defaults to `name` when created without a full name on macOS
      apply = v: if v != "" then v else name;
      description = ''
        A short description of the user account, typically the
        user's full name.
      '';
    };

    uid = mkOption {
      type = with types; nullOr int;
      default = null;
      description = ''
        The account UID. If the UID is null, a free UID is picked on
        activation.
      '';
    };

    gid = mkOption {
      type = types.int;
      default = 20;
      description = "The user's primary group.";
    };

    isHidden = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to make the user account hidden.";
    };

    # extraGroups = mkOption {
    #   type = types.listOf types.str;
    #   default = [];
    #   description = "The user's auxiliary groups.";
    # };

    home = mkOption {
      type = types.path;
      default = "/var/empty";
      description = "The user's home directory.";
    };

    createHome = mkOption {
      type = types.bool;
      default = false;
      description = "Create the home directory when creating the user.";
    };

    isNormalUser = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Indicates whether this is an account for a “real” user.
        This automatically sets {option}`group` to `staff`,
        {option}`createHome` to `true`,
        {option}`home` to {file}`/Users/«username»`,
        and {option}`isSystemUser` to `false`.
        Exactly one of `isNormalUser` and `isSystemUser` must be true.
      '';
    };

    isSystemUser = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Indicates if the user is a system user or not. This option
        only has an effect if {option}`uid` is
        {option}`null`, in which case it determines whether
        the user's UID is allocated in the range for system users
        (between 200-400) or in the range for normal users (starting at
        501). The user's name must also begin with an underscore (`_`).
        Exactly one of `isNormalUser` and `isSystemUser` must be true.

        These are also known as role accounts in some macOS documentation.
      '';
    };

    shell = mkOption {
      type = types.either types.shellPackage types.path;
      default = if config.isNormalUser then "/bin/zsh" else "/usr/bin/false";
      defaultText = ''
        if config.users.users.<user>.isNormalUser then "/bin/zsh"
        else "/usr/bin/false"
      '';
      example = literalExpression "pkgs.bashInteractive";
      description = "The user's shell.";
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [];
      example = literalExpression "[ pkgs.firefox pkgs.thunderbird ]";
      description = ''
        The set of packages that should be made availabe to the user.
        This is in contrast to {option}`environment.systemPackages`,
        which adds packages to all users.
      '';
    };
  };
}
