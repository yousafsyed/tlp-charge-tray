using Gtk;
using AppIndicator;

public class ChargeControllerApp : Gtk.Application {
    private const string APP_ID = "io.github.yousaf.ChargeController";
    private const string ICON_NAME = "charge-controller";
    private const string BATTERY = "BAT0";
    private const string INSTALLED_HELPER = "/usr/lib/charge-controller/charge-controller-helper";

    private Indicator? indicator;
    private Gtk.MenuItem? status_item;
    private Gtk.MenuItem? service_item;
    private Gtk.MenuItem? limit_item;
    private Gtk.MenuItem? full_item;

    public ChargeControllerApp () {
        Object (
            application_id: APP_ID,
            flags: ApplicationFlags.FLAGS_NONE
        );
    }

    protected override void activate () {
        if (indicator != null) {
            refresh_status ();
            return;
        }

        build_indicator ();
        hold ();
    }

    private void build_indicator () {
        indicator = new Indicator (
            APP_ID,
            ICON_NAME,
            IndicatorCategory.HARDWARE
        );
        indicator.set_title ("Charge Controller");
        indicator.set_status (IndicatorStatus.ACTIVE);

        var menu = new Gtk.Menu ();

        status_item = new Gtk.MenuItem.with_label ("Reading battery...");
        status_item.sensitive = false;
        menu.append (status_item);

        service_item = new Gtk.MenuItem.with_label ("Checking TLP service...");
        service_item.sensitive = false;
        menu.append (service_item);

        var refresh_item = new Gtk.MenuItem.with_label ("Refresh status");
        refresh_item.activate.connect (() => refresh_status ());
        menu.append (refresh_item);

        menu.append (new Gtk.SeparatorMenuItem ());

        limit_item = new Gtk.MenuItem.with_label ("Limit to 80%");
        limit_item.activate.connect (() => apply_mode ("limit-80", "80% limit"));
        menu.append (limit_item);

        full_item = new Gtk.MenuItem.with_label ("Charge to 100%");
        full_item.activate.connect (() => apply_mode ("charge-100", "100% charge"));
        menu.append (full_item);

        menu.append (new Gtk.SeparatorMenuItem ());

        var quit_item = new Gtk.MenuItem.with_label ("Quit");
        quit_item.activate.connect (() => {
            release ();
            quit ();
        });
        menu.append (quit_item);

        menu.show_all ();
        indicator.set_menu (menu);

        refresh_status ();
        Timeout.add_seconds (30, () => {
            refresh_status ();
            return true;
        });
    }

    private void set_actions_sensitive (bool enabled) {
        if (limit_item != null) {
            limit_item.sensitive = enabled;
        }
        if (full_item != null) {
            full_item.sensitive = enabled;
        }
    }

    private void apply_mode (string mode, string display_name) {
        set_actions_sensitive (false);
        set_status_label ("Applying " + display_name + "...");
        drain_events ();

        string? stdout_text = null;
        string? stderr_text = null;

        try {
            string[] argv = { "pkexec", helper_path (), mode };
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
                var details = clean_message (stderr_text);
                if (details == "") {
                    details = clean_message (stdout_text);
                }
                if (details == "") {
                    details = "The helper exited without applying the setting.";
                }
                show_error ("Could not apply " + display_name, details);
            }
        } catch (Error err) {
            show_error ("Could not apply " + display_name, err.message);
        }

        refresh_status ();
        set_actions_sensitive (true);
    }

    private string helper_path () {
        var override_path = Environment.get_variable ("CHARGE_CONTROLLER_HELPER");
        if (override_path != null && override_path.strip () != "") {
            return override_path;
        }
        return INSTALLED_HELPER;
    }

    private void refresh_status () {
        var capacity = read_first ({
            "/sys/class/power_supply/" + BATTERY + "/capacity",
        }, "?");
        var charging_state = read_first ({
            "/sys/class/power_supply/" + BATTERY + "/status",
        }, "unknown");
        var start_threshold = read_first ({
            "/sys/class/power_supply/" + BATTERY + "/charge_control_start_threshold",
            "/sys/class/power_supply/" + BATTERY + "/charge_start_threshold",
        }, "?");
        var stop_threshold = read_first ({
            "/sys/class/power_supply/" + BATTERY + "/charge_control_end_threshold",
            "/sys/class/power_supply/" + BATTERY + "/charge_stop_threshold",
        }, "?");

        set_status_label (
            "Battery " + capacity + "% (" + charging_state + ") - thresholds " +
            start_threshold + "/" + stop_threshold
        );

        if (indicator != null) {
            indicator.set_label (capacity + "%", "100%");
        }

        refresh_tlp_service_status ();
    }

    private void refresh_tlp_service_status () {
        string? stdout_text = null;
        string? stderr_text = null;

        try {
            string[] argv = { "systemctl", "is-enabled", "tlp.service" };
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

            var state = clean_message (stdout_text);
            if (subprocess.get_successful () && state == "enabled") {
                set_service_label ("TLP service enabled");
                return;
            }

            if (state == "") {
                state = clean_message (stderr_text);
            }
            if (state == "") {
                state = "not enabled";
            }
            set_service_label ("TLP service: " + state);
        } catch (Error err) {
            set_service_label ("TLP service status unavailable");
        }
    }

    private void set_status_label (string label) {
        if (status_item != null) {
            status_item.set_label (label);
        }
    }

    private void set_service_label (string label) {
        if (service_item != null) {
            service_item.set_label (label);
        }
    }

    private string read_first (string[] paths, string fallback) {
        foreach (var path in paths) {
            string contents;
            try {
                FileUtils.get_contents (path, out contents);
                return contents.strip ();
            } catch (Error err) {
            }
        }

        return fallback;
    }

    private string clean_message (string? message) {
        if (message == null) {
            return "";
        }

        return message.strip ();
    }

    private void drain_events () {
        while (Gtk.events_pending ()) {
            Gtk.main_iteration ();
        }
    }

    private void show_error (string title, string details) {
        var dialog = new Gtk.MessageDialog (
            null,
            Gtk.DialogFlags.MODAL,
            Gtk.MessageType.ERROR,
            Gtk.ButtonsType.CLOSE,
            "%s",
            title
        );
        dialog.secondary_text = details;
        dialog.run ();
        dialog.destroy ();
    }
}

public int main (string[] args) {
    var app = new ChargeControllerApp ();
    return app.run (args);
}
