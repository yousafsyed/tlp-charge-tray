public errordomain HelperError {
    INVALID_MODE,
    NOT_ROOT,
    CONFIG,
    TLP
}

public struct ChargeMode {
    public string name;
    public int start_threshold;
    public int stop_threshold;
}

public class ChargeControllerHelper {
    private const string BATTERY = "BAT0";
    private const string TLP = "/usr/sbin/tlp";
    private const string TLP_CONF = "/etc/tlp.conf";
    private const string BACKUP = "/etc/tlp.conf.charge-controller.bak";
    private const string BLOCK_BEGIN = "# BEGIN charge-controller";
    private const string BLOCK_END = "# END charge-controller";

    public static int main (string[] args) {
        try {
            if (Posix.geteuid () != 0) {
                throw new HelperError.NOT_ROOT (
                    "charge-controller-helper must be run as root through pkexec."
                );
            }

            if (args.length != 2) {
                throw new HelperError.INVALID_MODE (
                    "Usage: charge-controller-helper limit-80|charge-100"
                );
            }

            var mode = parse_mode (args[1]);
            ensure_backup ();
            apply_tlp_thresholds (mode);
            update_tlp_config (mode);

            stdout.printf (
                "Applied %s: BAT0 thresholds %d/%d\n",
                mode.name,
                mode.start_threshold,
                mode.stop_threshold
            );
            return 0;
        } catch (Error err) {
            stderr.printf ("%s\n", err.message);
            return 1;
        }
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

    private static void update_tlp_config (ChargeMode mode) throws Error {
        string contents;
        FileUtils.get_contents (TLP_CONF, out contents);

        var cleaned = remove_managed_block (contents).strip ();
        var block = build_managed_block (mode);
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

    private static string build_managed_block (ChargeMode mode) {
        return "%s\n".printf (BLOCK_BEGIN) +
            "# Managed by Charge Controller. Manual changes inside this block may be overwritten.\n" +
            "START_CHARGE_THRESH_%s=%d\n".printf (BATTERY, mode.start_threshold) +
            "STOP_CHARGE_THRESH_%s=%d\n".printf (BATTERY, mode.stop_threshold) +
            "%s".printf (BLOCK_END);
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
}
