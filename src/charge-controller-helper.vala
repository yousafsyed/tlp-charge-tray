public errordomain HelperError {
    INVALID_MODE,
    NOT_ROOT,
    CONFIG,
    TLP,
    GOVERNOR
}

public struct ChargeMode {
    public string name;
    public int start_threshold;
    public int stop_threshold;
}

// Parsed contents of the managed tlp.conf block. Each dimension is optional so
// charge thresholds and CPU governor settings can be managed independently
// without one overwriting the other.
public class ManagedSettings {
    public bool has_charge = false;
    public int start_threshold = 0;
    public int stop_threshold = 0;

    public bool has_governor = false;
    public string governor_ac = "";
    public string governor_bat = "";
}

public class ChargeControllerHelper {
    private const string BATTERY = "BAT0";
    private const string TLP = "/usr/sbin/tlp";
    private const string TLP_CONF = "/etc/tlp.conf";
    private const string BACKUP = "/etc/tlp.conf.charge-controller.bak";
    private const string BLOCK_BEGIN = "# BEGIN charge-controller";
    private const string BLOCK_END = "# END charge-controller";
    private const string CPU_BASE = "/sys/devices/system/cpu";
    private const string AC_ONLINE = "/sys/class/power_supply/AC/online";

    public static int main (string[] args) {
        try {
            if (Posix.geteuid () != 0) {
                throw new HelperError.NOT_ROOT (
                    "charge-controller-helper must be run as root through pkexec."
                );
            }

            if (args.length < 2) {
                throw new HelperError.INVALID_MODE (usage ());
            }

            switch (args[1]) {
                case "limit-80":
                case "charge-100":
                    apply_charge (parse_mode (args[1]));
                    break;
                case "governor-auto":
                    apply_governor_auto ();
                    break;
                case "governor-set":
                    if (args.length != 3) {
                        throw new HelperError.GOVERNOR (
                            "Usage: charge-controller-helper governor-set <governor>"
                        );
                    }
                    apply_governor_set (args[2]);
                    break;
                default:
                    throw new HelperError.INVALID_MODE (usage ());
            }

            return 0;
        } catch (Error err) {
            stderr.printf ("%s\n", err.message);
            return 1;
        }
    }

    private static string usage () {
        return "Usage: charge-controller-helper " +
            "limit-80|charge-100|governor-auto|governor-set <governor>";
    }

    private static void apply_charge (ChargeMode mode) throws Error {
        ensure_backup ();
        apply_tlp_thresholds (mode);

        var settings = read_managed_settings ();
        settings.has_charge = true;
        settings.start_threshold = mode.start_threshold;
        settings.stop_threshold = mode.stop_threshold;
        write_managed_settings (settings);

        stdout.printf (
            "Applied %s: BAT0 thresholds %d/%d\n",
            mode.name,
            mode.start_threshold,
            mode.stop_threshold
        );
    }

    private static void apply_governor_auto () throws Error {
        ensure_backup ();

        var balanced = balanced_governor ();
        var settings = read_managed_settings ();
        settings.has_governor = true;
        settings.governor_ac = "performance";
        settings.governor_bat = balanced;
        write_managed_settings (settings);

        // Apply live to match the current power source; TLP keeps it in sync
        // afterwards on plug/unplug.
        var live = on_ac_power () ? "performance" : balanced;
        write_governor (live);

        stdout.printf (
            "Applied governor-auto: AC=performance BAT=%s (live=%s)\n",
            balanced,
            live
        );
    }

    private static void apply_governor_set (string requested) throws Error {
        var governor = requested.strip ();
        var available = available_governors ();
        if (!array_contains (available, governor)) {
            throw new HelperError.GOVERNOR (
                "Unknown governor '%s'. Available: %s".printf (
                    governor,
                    string.joinv (" ", available)
                )
            );
        }

        ensure_backup ();

        var settings = read_managed_settings ();
        settings.has_governor = true;
        settings.governor_ac = governor;
        settings.governor_bat = governor;
        write_managed_settings (settings);

        write_governor (governor);

        stdout.printf ("Applied governor-set: %s on AC and battery\n", governor);
    }

    private static ChargeMode parse_mode (string arg) throws HelperError {
        switch (arg) {
            case "limit-80":
                return ChargeMode () {
                    name = "limit-80",
                    start_threshold = 75,
                    stop_threshold = 80,
                };
            case "charge-100":
                return ChargeMode () {
                    name = "charge-100",
                    start_threshold = 96,
                    stop_threshold = 100,
                };
            default:
                throw new HelperError.INVALID_MODE (
                    "Invalid mode. Expected limit-80 or charge-100."
                );
        }
    }

    private static void ensure_backup () throws Error {
        if (FileUtils.test (BACKUP, FileTest.EXISTS)) {
            return;
        }

        string contents;
        FileUtils.get_contents (TLP_CONF, out contents);
        FileUtils.set_contents (BACKUP, contents);
    }

    // Parse the existing managed block so we can preserve settings from other
    // dimensions when rewriting it.
    private static ManagedSettings read_managed_settings () throws Error {
        var settings = new ManagedSettings ();

        if (!FileUtils.test (TLP_CONF, FileTest.EXISTS)) {
            return settings;
        }

        string contents;
        FileUtils.get_contents (TLP_CONF, out contents);

        foreach (var raw in contents.split ("\n")) {
            var line = raw.strip ();
            if (line.has_prefix ("START_CHARGE_THRESH_" + BATTERY + "=")) {
                settings.has_charge = true;
                settings.start_threshold = int.parse (value_after (line));
            } else if (line.has_prefix ("STOP_CHARGE_THRESH_" + BATTERY + "=")) {
                settings.has_charge = true;
                settings.stop_threshold = int.parse (value_after (line));
            } else if (line.has_prefix ("CPU_SCALING_GOVERNOR_ON_AC=")) {
                settings.has_governor = true;
                settings.governor_ac = value_after (line);
            } else if (line.has_prefix ("CPU_SCALING_GOVERNOR_ON_BAT=")) {
                settings.has_governor = true;
                settings.governor_bat = value_after (line);
            }
        }

        return settings;
    }

    private static string value_after (string line) {
        var idx = line.index_of ("=");
        if (idx < 0) {
            return "";
        }
        return line.substring (idx + 1).strip ();
    }

    private static void write_managed_settings (ManagedSettings settings) throws Error {
        string contents;
        FileUtils.get_contents (TLP_CONF, out contents);

        var cleaned = remove_managed_block (contents).strip ();
        var block = build_managed_block (settings);
        var updated = cleaned + "\n\n" + block + "\n";

        FileUtils.set_contents (TLP_CONF, updated);
    }

    private static string remove_managed_block (string contents) throws RegexError {
        var regex = new Regex (
            "^# BEGIN charge-controller\\R.*?^# END charge-controller\\R?",
            RegexCompileFlags.MULTILINE | RegexCompileFlags.DOTALL
        );

        return regex.replace (
            contents,
            contents.length,
            0,
            ""
        );
    }

    private static string build_managed_block (ManagedSettings settings) {
        var builder = new StringBuilder ();
        builder.append ("%s\n".printf (BLOCK_BEGIN));
        builder.append (
            "# Managed by Charge Controller. Manual changes inside this block may be overwritten.\n"
        );

        if (settings.has_charge) {
            builder.append (
                "START_CHARGE_THRESH_%s=%d\n".printf (BATTERY, settings.start_threshold)
            );
            builder.append (
                "STOP_CHARGE_THRESH_%s=%d\n".printf (BATTERY, settings.stop_threshold)
            );
        }

        if (settings.has_governor) {
            builder.append (
                "CPU_SCALING_GOVERNOR_ON_AC=%s\n".printf (settings.governor_ac)
            );
            builder.append (
                "CPU_SCALING_GOVERNOR_ON_BAT=%s\n".printf (settings.governor_bat)
            );
        }

        builder.append ("%s".printf (BLOCK_END));
        return builder.str;
    }

    private static void apply_tlp_thresholds (ChargeMode mode) throws Error {
        string? stdout_text = null;
        string? stderr_text = null;
        string start_value = mode.start_threshold.to_string ();
        string stop_value = mode.stop_threshold.to_string ();
        string[] argv = {
            TLP,
            "setcharge",
            start_value,
            stop_value,
            BATTERY,
        };

        var subprocess = new Subprocess.newv (
            argv,
            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE
        );

        subprocess.communicate_utf8 (
            null,
            null,
            out stdout_text,
            out stderr_text
        );

        if (!subprocess.get_successful ()) {
            var details = stderr_text == null ? "" : stderr_text.strip ();
            if (details == "") {
                details = stdout_text == null ? "" : stdout_text.strip ();
            }
            if (details == "") {
                details = "tlp setcharge failed.";
            }
            throw new HelperError.TLP (details);
        }
    }

    // Governors exposed by the active scaling driver, e.g. "performance powersave".
    private static string[] available_governors () {
        string[] result = {};
        string contents;
        try {
            FileUtils.get_contents (
                CPU_BASE + "/cpu0/cpufreq/scaling_available_governors",
                out contents
            );
        } catch (Error err) {
            return result;
        }

        foreach (var token in contents.strip ().split (" ")) {
            var name = token.strip ();
            if (name != "") {
                result += name;
            }
        }
        return result;
    }

    private static bool array_contains (string[] values, string needle) {
        foreach (var value in values) {
            if (value == needle) {
                return true;
            }
        }
        return false;
    }

    // On intel_pstate there is no literal "balanced" governor; powersave is the
    // dynamic one. Prefer schedutil/ondemand when present for portability.
    private static string balanced_governor () {
        var available = available_governors ();
        foreach (var preferred in new string[] { "schedutil", "ondemand", "powersave" }) {
            if (array_contains (available, preferred)) {
                return preferred;
            }
        }
        return "powersave";
    }

    private static bool on_ac_power () {
        string contents;
        try {
            FileUtils.get_contents (AC_ONLINE, out contents);
        } catch (Error err) {
            // Assume plugged in if we cannot tell, matching the performance default.
            return true;
        }
        return contents.strip () == "1";
    }

    // Write the governor directly to every CPU's scaling_governor node.
    private static void write_governor (string governor) throws Error {
        var dir = Dir.open (CPU_BASE, 0);
        string? name;
        var wrote_any = false;

        while ((name = dir.read_name ()) != null) {
            if (!name.has_prefix ("cpu")) {
                continue;
            }
            // Only cpuN directories (cpu0, cpu1, ...), not cpuidle/cpufreq.
            var suffix = name.substring (3);
            if (suffix == "" || !is_all_digits (suffix)) {
                continue;
            }

            var path = "%s/%s/cpufreq/scaling_governor".printf (CPU_BASE, name);
            if (!FileUtils.test (path, FileTest.EXISTS)) {
                continue;
            }

            write_sysfs (path, governor, name);
            wrote_any = true;
        }

        if (!wrote_any) {
            throw new HelperError.GOVERNOR (
                "No writable CPU scaling_governor nodes were found."
            );
        }
    }

    // sysfs nodes must be written in place; FileUtils.set_contents writes a temp
    // file and renames it, which sysfs rejects. Open and write the node directly.
    private static void write_sysfs (string path, string value, string label)
        throws HelperError {
        var fd = Posix.open (path, Posix.O_WRONLY);
        if (fd < 0) {
            throw new HelperError.GOVERNOR (
                "Failed to open %s: %s".printf (label, Posix.strerror (Posix.errno))
            );
        }

        var written = Posix.write (fd, (char[]) value.data, value.length);
        var write_errno = Posix.errno;
        Posix.close (fd);

        if (written < 0) {
            throw new HelperError.GOVERNOR (
                "Failed to set governor on %s: %s".printf (
                    label, Posix.strerror (write_errno)
                )
            );
        }
    }

    private static bool is_all_digits (string value) {
        for (int i = 0; i < value.length; i++) {
            if (!value[i].isdigit ()) {
                return false;
            }
        }
        return true;
    }
}
